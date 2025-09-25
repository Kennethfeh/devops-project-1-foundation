#!/bin/bash
# This script runs when the EC2 instance starts

# Update system
yum update -y

# Install Docker
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Get region from instance metadata
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

# Login to ECR (registry only)
ECR_REGISTRY="${ecr_registry}"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Create deployment script
cat > /home/ec2-user/deploy.sh << 'EOF'
#!/bin/bash
set -Eeuo pipefail
trap 'echo "Deployment failed at line $LINENO"' ERR

ECR_URI="${ecr_repository_uri}"
ECR_REGISTRY="${ecr_registry}"
AWS_REGION="${aws_region}"
IMAGE_TAG="$${1:-latest}"

echo "🚀 Starting deployment..."
echo "ECR URI: $ECR_URI"
echo "Image Tag: $IMAGE_TAG"

# Stop existing container
echo "Stopping existing container..."
docker stop devops-app || true
docker rm devops-app || true

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Pull latest image
echo "Pulling image $ECR_URI:$IMAGE_TAG"
if ! docker pull "$ECR_URI:$IMAGE_TAG"; then
  BRANCH_NAME=$(echo "$IMAGE_TAG" | cut -d'-' -f1)
  COMMIT_PART=$(echo "$IMAGE_TAG" | cut -d'-' -f2-)
  if [[ "$IMAGE_TAG" == *-* && ${#COMMIT_PART} -ge 7 ]]; then
    FALLBACK_TAG="$BRANCH_NAME-${COMMIT_PART:0:7}"
    echo "Primary tag not found, trying fallback $ECR_URI:$FALLBACK_TAG"
    docker pull "$ECR_URI:$FALLBACK_TAG"
    IMAGE_TAG="$FALLBACK_TAG"
  else
    echo "Image tag $IMAGE_TAG not found and no fallback available" >&2
    exit 1
  fi
fi

# Start new container
echo "Starting new container..."
docker run -d \
  --name devops-app \
  -p 3000:3000 \
  --restart unless-stopped \
  -e APP_VERSION="$IMAGE_TAG" \
  "$ECR_URI:$IMAGE_TAG"

echo "✅ Deployment complete!"
docker ps
EOF

# Make script executable
chmod +x /home/ec2-user/deploy.sh
chown ec2-user:ec2-user /home/ec2-user/deploy.sh

# Create log file
echo "✅ EC2 instance setup completed at $(date)" > /home/ec2-user/setup.log
