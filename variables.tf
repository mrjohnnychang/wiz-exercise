variable "mongo_user" {
  description = "The database admin username"
  type        = string
  sensitive   = true
}

variable "mongo_pass" {
  description = "The database admin password"
  type        = string
  sensitive   = true
}
