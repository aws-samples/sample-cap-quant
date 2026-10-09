provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "tpp"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}
