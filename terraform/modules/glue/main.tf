resource "aws_glue_catalog_database" "this" {
  count       = var.create_database ? 1 : 0
  name        = var.database_name
  description = var.database_description
}

resource "aws_glue_catalog_table" "this" {
  count         = var.create_table ? 1 : 0
  name          = var.table_name
  database_name = var.table_database_name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "json"
  }

  storage_descriptor {
    location      = var.table_location
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters            = var.table_serde_paths == null ? {} : { paths = var.table_serde_paths }
    }

    dynamic "columns" {
      for_each = var.table_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}
