variable "create_database" {
  description = "Whether this module instance creates a database."
  type        = bool
  default     = false
}

variable "database_name" {
  description = "Glue database name."
  type        = string
  default     = null
}

variable "database_description" {
  description = "Glue database description."
  type        = string
  default     = null
}

variable "create_table" {
  description = "Whether this module instance creates a table."
  type        = bool
  default     = false
}

variable "table_name" {
  description = "Glue table name."
  type        = string
  default     = null
}

variable "table_database_name" {
  description = "Database the table belongs to."
  type        = string
  default     = null
}

variable "table_location" {
  description = "S3 location for the table data."
  type        = string
  default     = null
}

variable "table_columns" {
  description = "Columns for the table."
  type = list(object({
    name = string
    type = string
  }))
  default = []
}

variable "table_serde_paths" {
  description = "Optional 'paths' parameter for the JsonSerDe (comma-separated string)."
  type        = string
  default     = null
}
