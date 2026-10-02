output "database_name" {
  value = try(aws_glue_catalog_database.this[0].name, null)
}

output "table_name" {
  value = try(aws_glue_catalog_table.this[0].name, null)
}
