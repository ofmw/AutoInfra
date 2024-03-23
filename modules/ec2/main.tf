# Security Group
resource "aws_security_group" "bastion-sg" {
  name   = "${var.naming}-bastion-sg"
  vpc_id = var.defVpcId

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.myIp]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.naming}-bastion-sg"
  }
}

resource "aws_security_group" "alb-sg" {
  name   = "${var.naming}-alb-sg"
  vpc_id = var.defVpcId

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.naming}-alb-sg"
  }
}

resource "aws_security_group" "ans-srv-sg" {
  name   = "${var.naming}-ans-srv-sg"
  vpc_id = var.defVpcId

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion-sg.id]
  }

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb-sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.naming}-ans-srv-sg"
  }
}

resource "aws_security_group" "ans-nod-sg" {
  name   = "${var.naming}-ans-nod-sg"
  vpc_id = var.defVpcId

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb-sg.id]
  }

  ingress {
    from_port       = 8888
    to_port         = 8888
    protocol        = "tcp"
    security_groups = [aws_security_group.alb-sg.id]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.ans-srv-sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.naming}-ans-nod-sg"
  }
}

# TargetGroup
resource "aws_lb_target_group" "service-tg" {
  name     = "${var.naming}-service-tg"
  port     = 8888
  protocol = "HTTP"
  vpc_id   = var.defVpcId

  health_check {
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group" "jenkins-tg" {
  name     = "${var.naming}-jenkins-tg"
  port     = 8080
  protocol = "HTTP"

  vpc_id = var.defVpcId

  health_check {
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# LoadBalancer
resource "aws_lb" "srv-alb" {
  name               = "${var.naming}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb-sg.id]
  subnets            = var.pubSubIds
}

output "srv-alb-name" {
  value = aws_lb.srv-alb.name
}

output "srv-alb-dns" {
  value = aws_lb.srv-alb.dns_name
}

# LB Listener
resource "aws_lb_listener" "srv-alb-http" {
  load_balancer_arn = aws_lb.srv-alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service-tg.arn
  }
}

resource "aws_lb_listener" "jenkins-alb-http" {
  load_balancer_arn = aws_lb.srv-alb.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins-tg.arn
  }
}

# aws_key_pair resource 설정
resource "aws_key_pair" "terraform-key-pair" {
  # 등록할 key pair의 name
  key_name = var.keyName

  # public_key = "{.pub 파일 내용}"
  public_key = file("./.ssh/${var.keyName}.pub")

  tags = {
    description = "terraform key pair import"
  }
}

# Instance
resource "aws_instance" "bastion-host" {
  ami             = var.bastionAmi
  instance_type   = "t3.micro"
  subnet_id       = var.pubSubIds[0]
  key_name        = var.keyName
  security_groups = [aws_security_group.bastion-sg.id]

  associate_public_ip_address = true

  tags = {
    Name = "${var.naming}-bastion-host"
  }
}

output "bastion-public-ip" {
  value = aws_instance.bastion-host.public_ip
}

resource "aws_instance" "ansible-server" {
  ami           = var.ansSrvAmi
  instance_type = var.ansSrvType
  subnet_id     = var.pvtSubIds[0]
  key_name      = var.keyName

  vpc_security_group_ids = [aws_security_group.ans-srv-sg.id]

  root_block_device {
    volume_size = var.ansSrvVolume
  }

  provisioner "local-exec" {
    command = "aws elbv2 register-targets --target-group-arn ${aws_lb_target_group.jenkins-tg.arn} --targets Id=${self.id}"
  }

  user_data = <<-EOF
              #!/bin/bash
              sudo hostnamectl set-hostname ansible-server
              sudo amazon-linux-extras enable ansible2
              sudo yum clean metadata
              sudo yum install -y ansible
              sudo yum install -y git
              EOF

  tags = {
    Name = "${var.naming}-ansible-server"
  }
}

output "ans-srv-pvt-ip" {
  value = aws_instance.ansible-server.private_ip
}

resource "aws_instance" "ansible-nod" {
  count         = var.ansNodCount
  ami           = var.ansNodAmi
  instance_type = var.ansNodType
  subnet_id     = var.pvtSubIds[0]
  key_name      = var.keyName

  vpc_security_group_ids = [aws_security_group.ans-nod-sg.id]

  root_block_device {
    volume_size = var.ansNodVolume
  }

  provisioner "local-exec" {
    command = "aws elbv2 register-targets --target-group-arn ${aws_lb_target_group.service-tg.arn} --targets Id=${self.id}"
  }

  user_data = <<-EOF
              #!/bin/bash
              sudo hostnamectl set-hostname ansible-agent0${count.index + 1}
              EOF

  tags = {
    Name = "${var.naming}-ansible-nod-0${count.index + 1}"
  }
}

output "ansible-nod-ips" {
  value = aws_instance.ansible-nod[*].private_ip
}
