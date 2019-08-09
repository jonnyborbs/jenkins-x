variable "key_pair_name" {
  description = "The name of the AWS Key Pair"
  default     = "JS-KeyPair"
}

variable "private_key" {
  description = "Private Key"
}
variable "public_key" {
  description = "Public Key"
}

variable "aws_region" {
  description = "AWS region to launch servers."
  default     = "us-east-1"
}