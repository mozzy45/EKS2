resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({
    env = {
      WARM_ENI_TARGET   = "1"
      WARM_IP_TARGET    = "1"
      MINIMUM_IP_TARGET = "2"
    }
  })

  lifecycle { create_before_destroy = true }
  depends_on = [aws_eks_node_group.main]
}

resource "kubernetes_cluster_role" "node_viewer" {
  metadata { name = "pod-node-viewer" }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "pod_node_viewer_binding" {
  metadata { name = "pod-node-viewer-binding" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.node_viewer.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "default"
  }
}

resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name      = "nginx-pod-app"
    namespace = "default"
    labels    = { app = "nginx-pod" }
  }

  spec {
    replicas = 2
    selector { match_labels = { app = "nginx-pod" } }

    template {
      metadata { labels = { app = "nginx-pod" } }
      spec {
        init_container {
          name  = "init-html"
          image = "alpine/k8s:1.29.2"
          
          # INJECT THE MISSING ENVIRONMENT VARIABLE HERE:
          env {
            name = "MY_NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
 
          command = [
            "/bin/bash",
            "-c",
            "sleep 5; PROVIDER_ID=$(kubectl get node $MY_NODE_NAME -o jsonpath='{.spec.providerID}'); INSTANCE_ID=$(echo $PROVIDER_ID | awk -F'/' '{print $5}'); echo \"Hello from EC2 instance $INSTANCE_ID\" > /usr/share/nginx/html/index.html"
          ]


          volume_mount {
            name       = "shared-html"
            mount_path = "/usr/share/nginx/html"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        container {
          image = "nginx:1.27"
          name  = "nginx"
          port { container_port = 80 }

          volume_mount {
            name       = "shared-html"
            mount_path = "/usr/share/nginx/html"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
        }

        volume {
          name = "shared-html"
          empty_dir {}
        }
      }
    }
  }
  depends_on = [aws_eks_node_group.main, kubernetes_cluster_role_binding.pod_node_viewer_binding]
}

resource "kubernetes_service_v1" "nginx_pod_service" {
  metadata {
    name      = "nginx-pod-service"
    namespace = "default"
  }

  spec {
    selector = { app = "nginx-pod" }
    port {
      port        = 80
      target_port = 80
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "nginx_ingress" {
  metadata {
    name      = "nginx-ingress"
    namespace = "default"
    annotations = {
      "kubernetes.io/ingress.class"           = "alb"
      "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
    }
  }

  spec {
    default_backend {
      service {
        name = kubernetes_service_v1.nginx_pod_service.metadata[0].name
        port { number = 80 }
      }
    }

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.nginx_pod_service.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }

# FIX: Expanded dependencies to keep the EKS engine active until the ALB is deleted
  depends_on = [
    helm_release.alb_controller,
    kubernetes_deployment_v1.nginx,
    aws_eks_node_group.main,
    aws_eks_cluster.main
  ]

}

output "alb_dns_name" {
  # FIXED: Wrapped in try() to return a helpful string instead of crashing if the array is empty
  value       = try(kubernetes_ingress_v1.nginx_ingress.status[0].load_balancer[0].ingress[0].hostname, "ALB is still provisioning, check again in a moment...")
  description = "The public DNS name of the provisioned AWS Application Load Balancer targeting Pod IPs."
}

# CHANGED resource name to 'metrics_server_v2' to completely clear the corrupted cache
resource "helm_release" "metrics_server_v2" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2" # Incremented slightly to force a fresh index pull
}

resource "kubernetes_horizontal_pod_autoscaler_v1" "nginx_hpa" {
  metadata {
    name      = "nginx-pod-app-hpa"
    namespace = "default"
  }

  spec {
    max_replicas = 10
    min_replicas = 2

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.nginx.metadata[0].name
    }

    target_cpu_utilization_percentage = 50
  }

  # UPDATED dependency target here to match new resource name
  depends_on = [helm_release.metrics_server_v2]
}
