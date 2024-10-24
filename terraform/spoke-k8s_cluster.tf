locals {
  streams = [
    "Microsoft-ContainerLog",
    "Microsoft-ContainerLogV2",
    "Microsoft-KubeEvents",
    "Microsoft-KubePodInventory",
    "Microsoft-KubeNodeInventory",
    "Microsoft-KubePVInventory",
    "Microsoft-KubeServices",
    "Microsoft-KubeMonAgentEvents",
    "Microsoft-InsightsMetrics",
    "Microsoft-ContainerInventory",
    "Microsoft-ContainerNodeInventory",
    "Microsoft-Perf"
  ]
}

data "http" "myip" {
  url = "https://ipv4.icanhazip.com"
}

data "azurerm_kubernetes_service_versions" "current" {
  location        = azurerm_resource_group.azure_resource_group.location
  include_preview = false
}

resource "azurerm_container_registry" "container_registry" {
  name                          = var.acr_login_server
  resource_group_name           = azurerm_resource_group.azure_resource_group.name
  location                      = azurerm_resource_group.azure_resource_group.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = true
  anonymous_pull_enabled        = false
}

resource "azurerm_log_analytics_workspace" "log_analytics" {
  name                = "log-analytics"
  location            = azurerm_resource_group.azure_resource_group.location
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_user_assigned_identity" "my_identity" {
  name                = "UserAssignedIdentity"
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  location            = azurerm_resource_group.azure_resource_group.location
}

resource "azurerm_role_assignment" "kubernetes_contributor" {
  principal_id         = azurerm_user_assigned_identity.my_identity.principal_id
  role_definition_name = "Contributor"
  scope                = azurerm_resource_group.azure_resource_group.id
}

resource "azurerm_role_assignment" "route_table_network_contributor" {
  principal_id                     = azurerm_user_assigned_identity.my_identity.principal_id
  role_definition_name             = "Network Contributor"
  scope                            = azurerm_resource_group.azure_resource_group.id
  skip_service_principal_aad_check = true
}

resource "azurerm_kubernetes_cluster" "kubernetes_cluster" {
  depends_on          = [azurerm_virtual_network_peering.spoke-to-hub_virtual_network_peering, azurerm_linux_virtual_machine.hub-nva_virtual_machine]
  name                = "spoke_kubernetes_cluster"
  location            = azurerm_resource_group.azure_resource_group.location
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  dns_prefix          = azurerm_resource_group.azure_resource_group.name
  #kubernetes_version                = data.azurerm_kubernetes_service_versions.current.latest_version
  #sku_tier = "Premium"
  #support_plan                      = "AKSLongTermSupport"
  #kubernetes_version                = "1.27"
  sku_tier                          = "Standard"
  cost_analysis_enabled             = true
  support_plan                      = "KubernetesOfficial"
  kubernetes_version                = "1.30"
  node_resource_group               = "MC-${azurerm_resource_group.azure_resource_group.name}"
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  #api_server_access_profile {
  #  authorized_ip_ranges = [
  #    "${chomp(data.http.myip.response_body)}/32"
  #  ]
  #}
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.log_analytics.id
    msi_auth_for_monitoring_enabled = true
  }
  default_node_pool {
    temporary_name_for_rotation = "rotation"
    name                        = "system"
    node_count                  = 1
    vm_size                     = local.vm-image["aks"].size
    os_sku                      = "AzureLinux"
    max_pods                    = "75"
    orchestrator_version        = "1.30"
    vnet_subnet_id              = azurerm_subnet.spoke_subnet.id
    upgrade_settings {
      max_surge = "10%"
    }
  }
  network_profile {
    #network_plugin    = "azure"
    network_plugin = "kubenet"
    #network_plugin = "none"
    #outbound_type     = "loadBalancer" 
    #network_policy    = "azure"
    load_balancer_sku = "standard"
    #service_cidr      = var.spoke-aks-subnet_prefix
    #dns_service_ip    = var.spoke-aks_dns_service_ip
    pod_cidr = var.spoke-aks_pod_cidr
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.my_identity.id]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "node-pool" {
  count                 = var.spoke-k8s-node-pool-gpu ? 1 : 0
  name                  = "gpu"
  mode                  = "User"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.kubernetes_cluster.id
  vm_size               = local.vm-image["aks"].gpu-size
  node_count            = 1
  os_sku                = "AzureLinux"
  node_taints           = ["nvidia.com/gpu=true:NoSchedule"]
  node_labels = {
    "nvidia.com/gpu.present" = "true"
  }
  os_disk_type      = "Ephemeral"
  ultra_ssd_enabled = true
  os_disk_size_gb   = "256"
  max_pods          = "50"
  zones             = ["1"]
  vnet_subnet_id    = azurerm_subnet.spoke_subnet.id
}

resource "azurerm_role_assignment" "acr_role_assignment" {
  principal_id                     = azurerm_kubernetes_cluster.kubernetes_cluster.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.container_registry.id
  skip_service_principal_aad_check = true
}

resource "azurerm_monitor_data_collection_rule" "this" {
  name                = "rule-${azurerm_resource_group.azure_resource_group.name}-${azurerm_resource_group.azure_resource_group.location}"
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  location            = azurerm_resource_group.azure_resource_group.location
  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.log_analytics.id
      name                  = "ciworkspace"
    }
  }
  data_flow {
    streams      = local.streams
    destinations = ["ciworkspace"]
  }
  data_sources {
    extension {
      streams        = local.streams
      extension_name = "ContainerInsights"
      extension_json = jsonencode({
        "dataCollectionSettings" : {
          "interval" : "1m",
          "namespaceFilteringMode" : "Off",
          "namespaces" : ["kube-system", "gatekeeper-system", "azure-arc"],
          "enableContainerLogV2" : true
        }
      })
      name = "ContainerInsightsExtension"
    }
  }
  description = "DCR for Azure Monitor Container Insights"
}

resource "azurerm_monitor_data_collection_rule_association" "this" {
  name                    = "ruleassoc-${azurerm_resource_group.azure_resource_group.name}-${azurerm_resource_group.azure_resource_group.location}"
  target_resource_id      = azurerm_kubernetes_cluster.kubernetes_cluster.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.this.id
  description             = "Association of container insights data collection rule. Deleting this association will break the data collection for this AKS Cluster."
}

resource "null_resource" "kube_config" {
  #triggers = {
  #  kube_config_exists = "${fileexists("~/.kube/config")}"
  #}
  triggers = {
    always = timestamp()
  }
  depends_on = [azurerm_kubernetes_cluster.kubernetes_cluster]
  provisioner "local-exec" {
    command = "[ -d \"$HOME/.kube\" ] || mkdir -p \"$HOME/.kube\" && echo \"${azurerm_kubernetes_cluster.kubernetes_cluster.kube_config_raw}\" > $HOME/.kube/config && chmod 600 $HOME/.kube/config"
  }
}

#resource "null_resource" "flannel" {
#  depends_on = [ null_resource.kube_config ]
#  provisioner "local-exec" {
#    command = "kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
#  }
#}

resource "azurerm_kubernetes_cluster_extension" "flux_extension" {
  name              = "flux-extension"
  cluster_id        = azurerm_kubernetes_cluster.kubernetes_cluster.id
  extension_type    = "microsoft.flux"
  release_namespace = "flux-system"
  depends_on        = [azurerm_kubernetes_cluster.kubernetes_cluster]
  configuration_settings = {
    "image-automation-controller.enabled" = true,
    "image-reflector-controller.enabled"  = true,
    "helm-controller.detectDrift"         = true,
    "notification-controller.enabled"     = true
  }
}

resource "null_resource" "secret" {
  triggers = {
    always_run = timestamp()
  }
  depends_on = [null_resource.kube_config]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOF
      kubectl apply -f - <<EOF2
      ---
      apiVersion: v1
      kind: Namespace
      metadata:
        name: application
        labels:
          name: application
      ---
      apiVersion: v1
      kind: Secret
      metadata:
        name: fortiweb-login-secret
        namespace: application
      type: Opaque
      data:
        username: $(echo -n "${random_pet.admin_username.id}" | base64)
        password: $(echo -n "${random_password.admin_password.result}" | base64)
      EOF2
    EOF
  }
}

data "git_repository" "current" {
  path = "${path.module}/.."
}

data "external" "git_url" {
  program = ["sh", "-c", "git -C ${path.module}/.. config --get remote.origin.url | jq -R -r 'split(\"\\n\") | map(select(length > 0)) | map({url: .}) | add'"]
}

resource "azurerm_kubernetes_flux_configuration" "flux_configuration" {
  name                              = "flux-configuration"
  cluster_id                        = azurerm_kubernetes_cluster.kubernetes_cluster.id
  namespace                         = "cluster-config"
  scope                             = "cluster"
  continuous_reconciliation_enabled = true
  git_repository {
    url                      = data.external.git_url.result["url"]
    reference_type           = "branch"
    reference_value          = data.git_repository.current.branch
    sync_interval_in_seconds = 60
    ssh_private_key_base64 = base64encode(var.control_repo_ssh_private_key)
  }
  kustomizations {
    name                       = "infrastructure"
    recreating_enabled         = true
    garbage_collection_enabled = true
    path                       = "./manifests/infrastructure"
    sync_interval_in_seconds   = 60
  }
  kustomizations {
    name                       = "apps"
    recreating_enabled         = true
    garbage_collection_enabled = true
    path                       = "./manifests/apps"
    sync_interval_in_seconds   = 60
    depends_on                 = ["infrastructure"]
  }
  kustomizations {
    name                       = "ingress"
    recreating_enabled         = true
    garbage_collection_enabled = true
    path                       = "./manifests/ingress"
    sync_interval_in_seconds   = 60
    depends_on                 = ["apps"]
  }
  depends_on = [
    azurerm_kubernetes_cluster_extension.flux_extension
  ]
}


