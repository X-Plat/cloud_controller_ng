Sequel.migration do
  change do
    alter_table(:apps) do
      add_column :cpu_quota, String, default: "0.1", null: false
    end
  end
end
