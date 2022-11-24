terraform {
  backend "s3" {
    bucket         = "eth-infra-tfstate" # create your own bucket for the state (you can add lock feature with dynamodb)
    region         = "eu-west-1"
    key            = "eth-infra-dev/terraform.tfstate"
    encrypt        = true
  }
}