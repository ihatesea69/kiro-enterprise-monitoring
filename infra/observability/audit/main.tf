# Dashboard "Kiro Request Audit - <customer>" (task 8.2, apply is [XÁC NHẬN]).
# Reads only the view kiro_<slug>.kiro_request_audit built by
# tools/build_audit_views.py, which never selects source IP or the full user agent.
# Direct Query, not SPICE (decision D10): no daily refresh re-reads 13 months of
# trail logs, and nothing is stored in SPICE. Each visual runs one Athena query
# when the dashboard opens.
# Provider: observability account, QuickSight Region (D6).
#
# [CHƯA XÁC MINH] Not yet planned against a real QuickSight account: the
# definition below passes the provider schema (terraform test with a mock
# provider), but QuickSight validates layouts and field types only at apply.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

variable "slug" {
  type = string
}

variable "display_name" {
  type = string
}

variable "athena_workgroup" {
  description = "The sample's workgroup kiro_<slug>, whose results bucket QuickSight can already write."
  type        = string
}

variable "owner_arn" {
  description = "QuickSight user or group ARN that owns the assets (QS_PRINCIPAL_ARN of the sample)."
  type        = string
}

variable "viewer_arns" {
  description = "D1: QuickSight users or groups allowed to view. Each reader costs money."
  type        = list(string)
  default     = []
}

variable "request_ids_match" {
  description = "OQ-2. false adds a note that CloudTrail and prompt metadata cannot be joined per request."
  type        = bool
  default     = false
}

locals {
  id       = "kiro-mon-audit-${var.slug}"
  database = "kiro_${replace(var.slug, "-", "_")}"
  columns = [
    ["event_time", "DATETIME"], ["event_name", "STRING"], ["request_id", "STRING"],
    ["error_code", "STRING"], ["error_message_present", "BOOLEAN"], ["account_id", "STRING"],
    ["region", "STRING"], ["user_id", "STRING"], ["user_label", "STRING"], ["client", "STRING"],
    ["conversation_id", "STRING"], ["prompt_chars", "INTEGER"], ["response_chars", "INTEGER"],
  ]
  table_fields = ["event_time", "user_label", "event_name", "error_code", "client", "request_id", "conversation_id"]
  note         = "CloudTrail and prompt metadata cannot be joined per request: their request IDs differ (OQ-2). Join by user and day only."

  ds_owner_actions   = ["quicksight:DescribeDataSource", "quicksight:DescribeDataSourcePermissions", "quicksight:PassDataSource", "quicksight:UpdateDataSource", "quicksight:DeleteDataSource", "quicksight:UpdateDataSourcePermissions"]
  set_owner_actions  = ["quicksight:DescribeDataSet", "quicksight:DescribeDataSetPermissions", "quicksight:PassDataSet", "quicksight:DescribeIngestion", "quicksight:ListIngestions", "quicksight:UpdateDataSet", "quicksight:DeleteDataSet", "quicksight:CreateIngestion", "quicksight:CancelIngestion", "quicksight:UpdateDataSetPermissions"]
  dash_owner_actions = ["quicksight:DescribeDashboard", "quicksight:ListDashboardVersions", "quicksight:UpdateDashboardPermissions", "quicksight:QueryDashboard", "quicksight:UpdateDashboard", "quicksight:DeleteDashboard", "quicksight:DescribeDashboardPermissions", "quicksight:UpdateDashboardPublishedVersion"]
  dash_view_actions  = ["quicksight:DescribeDashboard", "quicksight:ListDashboardVersions", "quicksight:QueryDashboard"]
}

resource "aws_quicksight_data_source" "this" {
  data_source_id = local.id
  name           = "Kiro request audit - ${var.display_name}"
  type           = "ATHENA"
  parameters {
    athena {
      work_group = var.athena_workgroup
    }
  }
  permission {
    principal = var.owner_arn
    actions   = local.ds_owner_actions
  }
}

resource "aws_quicksight_data_set" "this" {
  data_set_id = local.id
  name        = "Kiro request audit - ${var.display_name}"
  import_mode = "DIRECT_QUERY"

  physical_table_map {
    physical_table_map_id = "audit"
    custom_sql {
      data_source_arn = aws_quicksight_data_source.this.arn
      name            = "kiro_request_audit"
      sql_query       = "SELECT * FROM ${local.database}.kiro_request_audit"
      dynamic "columns" {
        for_each = local.columns
        content {
          name = columns.value[0]
          type = columns.value[1]
        }
      }
    }
  }

  permissions {
    principal = var.owner_arn
    actions   = local.set_owner_actions
  }
}

resource "aws_quicksight_dashboard" "this" {
  dashboard_id        = local.id
  name                = "Kiro Request Audit - ${var.display_name}"
  version_description = "kiro-enterprise-monitoring"

  definition {
    data_set_identifiers_declarations {
      identifier   = "audit"
      data_set_arn = aws_quicksight_data_set.this.arn
    }

    sheets {
      sheet_id = "requests"
      name     = "Requests"

      dynamic "text_boxes" {
        for_each = var.request_ids_match ? [] : [1]
        content {
          sheet_text_box_id = "oq2-note"
          content           = local.note
        }
      }

      visuals {
        table_visual {
          visual_id = "requests-table"
          title {
            format_text {
              plain_text = "Kiro requests by user"
            }
          }
          chart_configuration {
            field_wells {
              table_unaggregated_field_wells {
                dynamic "values" {
                  for_each = local.table_fields
                  content {
                    field_id = values.value
                    column {
                      data_set_identifier = "audit"
                      column_name         = values.value
                    }
                  }
                }
              }
            }
          }
        }
      }

      layouts {
        configuration {
          grid_layout {
            dynamic "elements" {
              for_each = var.request_ids_match ? [] : [1]
              content {
                element_id   = "oq2-note"
                element_type = "TEXT_BOX"
                column_span  = 36
                row_span     = 2
              }
            }
            elements {
              element_id   = "requests-table"
              element_type = "VISUAL"
              column_span  = 36
              row_span     = 18
            }
          }
        }
      }
    }
  }

  permissions {
    principal = var.owner_arn
    actions   = local.dash_owner_actions
  }

  dynamic "permissions" {
    for_each = toset(var.viewer_arns)
    content {
      principal = permissions.value
      actions   = local.dash_view_actions
    }
  }
}

output "dashboard_id" {
  value = aws_quicksight_dashboard.this.dashboard_id
}
