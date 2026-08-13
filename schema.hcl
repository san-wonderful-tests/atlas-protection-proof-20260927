schema "public" {
}

table "projects" {
  schema = schema.public

  column "id" {
    type = uuid
    null = false
  }

  column "tenant_id" {
    type = uuid
    null = false
  }

  column "name" {
    type = text
    null = false
  }

  column "owner_email" {
    type = text
    null = true
  }

  primary_key {
    columns = [column.id]
  }

  index "idx_projects_tenant_name" {
    unique  = true
    columns = [column.tenant_id, column.name]
  }
}
