# --- 1. CORE NETWORKING ENGINE ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "eks-automated-lifecycle-vpc"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "eks-igw" }
}

# --- 2. SUBNETS CONFIGURATION WITH DISCOVERY TAGS ---
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                   = "eks-public-subnet-${count.index}"
    "kubernetes.io/role/elb"               = "1"
    "kubernetes.io/cluster/my-eks-cluster" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                   = "eks-private-subnet-${count.index}"
    "kubernetes.io/role/internal-elb"      = "1"
    "kubernetes.io/cluster/my-eks-cluster" = "shared"
  }
}

# --- 3. NAT GATEWAY ENGINE ---
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.gw]
}

# --- 4. ROUTE TABLES ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "eks-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "eks-private-rt" }
}

# --- 5. LOOPED ROUTE TABLE ASSOCIATIONS ---
resource "aws_route_table_association" "public" {
  count = 2
  # FIXED: Wrapped in correct list element interpolation format
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2
  # FIXED: Wrapped in correct list element interpolation format
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

