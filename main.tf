# 0. THE DYNAMIC AMI LOOKUP (Added this so we stop hitting "AMI Not Found" errors)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    # This searches for the official Amazon Linux 2023 images
    values = ["al2023-ami-2023*-x86_64"] 
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# 1. THE VPC
resource "aws_vpc" "project_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "Project11-VPC"
  }
}

# 2. THE PUBLIC SUBNET
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.project_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "Public-Subnet"
  }
}

# 3. THE INTERNET GATEWAY
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.project_vpc.id

  tags = {
    Name = "Project11-IGW"
  }
}

# 4. THE ROUTE TABLE
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.project_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "Public-Route-Table"
  }
}

# 5. THE ASSOCIATION
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 6. SECURITY GROUP
resource "aws_security_group" "web_sg" {
  name        = "web-server-sg"
  description = "Allow HTTP and SSH traffic"
  vpc_id      = aws_vpc.project_vpc.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Web-SG"
  }
}

# 7. LAUNCH TEMPLATE
resource "aws_launch_template" "web_lt" {
  name_prefix   = "web-server-template-"
  
  # WORD-BY-WORD: We are using the ID found by the data source above
  image_id      = data.aws_ami.amazon_linux_2023.id 
  
  instance_type = "t3.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  # WORD-BY-WORD: Using 'dnf' because AL2023 uses it instead of 'yum'
  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello from Project 11 - Two-Tier Infra</h1>" > /var/www/html/index.html
              EOF
  )
}

# 8. AUTO SCALING GROUP
resource "aws_autoscaling_group" "web_asg" {
  name                = "project11-asg"
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  target_group_arns = [aws_lb_target_group.web_tg.arn]
  vpc_zone_identifier = [aws_subnet.public_subnet.id, aws_subnet.public_subnet_2.id]

  launch_template {
    id      = aws_launch_template.web_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Project11-Instance"
    propagate_at_launch = true
  }
}
# 10. SECOND PUBLIC SUBNET (For High Availability in a different building/AZ)
resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.project_vpc.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b" # Different from us-east-1a

  tags = {
    Name = "Public-Subnet-2"
  }
}

# 11. ASSOCIATE SECOND SUBNET WITH THE ROUTE TABLE
resource "aws_route_table_association" "public_assoc_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}
# 12. THE LOAD BALANCER (The Single Entry Point)
resource "aws_lb" "project_alb" {
  name               = "project-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [aws_subnet.public_subnet.id, aws_subnet.public_subnet_2.id]
}

# 13. TARGET GROUP (The list of servers to send traffic to)
resource "aws_lb_target_group" "web_tg" {
  name     = "web-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.project_vpc.id

  health_check {
    path = "/" # Check the main page to see if the server is alive
    port = "80"
  }
}

# 14. LISTENER (The ears of the Load Balancer)
resource "aws_lb_listener" "web_listener" {
  load_balancer_arn = aws_lb.project_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}
# 15. PRIVATE SUBNETS (The "Vault" for the Database)
resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.project_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "Private-Subnet-1"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.project_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "Private-Subnet-2"
  }
}

# 16. DB SUBNET GROUP (AWS requires this to group private subnets for RDS)
resource "aws_db_subnet_group" "db_group" {
  name       = "project11-db-group"
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]

  tags = {
    Name = "My-DB-Subnet-Group"
  }
}
# 17. DATABASE SECURITY GROUP (The Inner Gate)
resource "aws_security_group" "db_sg" {
  name        = "db-server-sg"
  description = "Allow traffic only from the Web Security Group"
  vpc_id      = aws_vpc.project_vpc.id

  ingress {
    description     = "Allow MySQL/Aurora from Web SG"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    # WORD-BY-WORD: This links the DB security to the Web security.
    # It says: "If you have the web_sg, you can enter."
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Database-SG"
  }
}
# 18. THE DATABASE (The Second Tier)
resource "aws_db_instance" "project_db" {
  allocated_storage      = 20
  db_name                = "project11db"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  username               = "admin"
  password               = "password123" # In real life, use a Secret Manager!
  parameter_group_name   = "default.mysql8.0"
  db_subnet_group_name   = aws_db_subnet_group.db_group.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
  multi_az               = false # Set to true for even higher availability
}
