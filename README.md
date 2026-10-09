# DMZ-VPC 统一公网出入口 Landing Zone

在火山引擎上部署一套集中式的公网出入口 Landing Zone，覆盖网络、路由、公网出向（NAT）、公网入向（ALB）、带宽聚合与工作负载等核心资源。该方案的云资源**全部通过 `volcenginecc`（Cloud Control）Provider 创建**，并配合 `hashicorp/time` Provider 提供仅在销毁时生效的等待屏障；通过中转路由器 Transit Router 将 dmz / dev / prd 三个 VPC 组成星型拓扑，把公网出向收敛到 dmz NAT、公网入向收敛到 dmz 公网 ALB，并将 NAT EIP 与所有可用区的 ALB EIP 纳入共享带宽包，一键 `terraform apply` 即可完成交付。

## 1. 业务背景

随着企业上云，多业务线 / 多环境的 VPC 数量快速膨胀，传统“每个 VPC 各自挂 EIP / NAT”的做法通常会遇到以下问题：

- **公网出向碎片化**：每个 VPC 独立分配 NAT + EIP，出向 IP 散乱难治理、白名单维护成本高、带宽难以聚合议价。
- **公网入向暴露面大**：每个 VPC 都对外开放 ALB/SLB，安全审计与 WAF 部署点分散，攻击面成倍增长。
- **跨 VPC 互通混乱**：业务流量在多个 VPC 间走 VPN / 对等连接拼接，路由策略难以集中管理，故障排查链路长。
- **扩展和回收成本高**：手工搭建多 VPC 互联环境易出错，验证结束后也需要可靠销毁资源，降低闲置成本。

本方案通过 Terraform 将上述基础设施标准化、模块化，落地一套**集中式 DMZ-VPC**，帮助用户快速完成统一公网出入口环境的交付。

## 2. 方案概述

整体采用集中式“公网出入口枢纽”架构：

- **接入层（入向）**：dmz VPC 内的公网 ALB 承接互联网 HTTP/HTTPS 流量，经 TR 反向转发到 prd 工作负载。
- **出向层**：dmz VPC 内的公网 NAT 网关 + 单一 EIP 承载统一出向，dev VPC 默认路由经 TR 收敛到此出向。
- **路由枢纽**：中转路由器 Transit Router 作为中央路由枢纽，dmz / dev / prd 三 VPC 各挂一个 VPC Attachment，专用 TR 子网作为连接点。
- **工作负载层**：dev / prd 两个业务 VPC 跨可用区部署 ECS，dmz VPC 仅承载出入口组件。
- **带宽聚合**：1 个 NAT EIP 与每个可用区各 1 个的 ALB 内置 EIP 纳入同一共享带宽包，集中议价、计费、限速。
- **安全控制**：每 VPC 独立安全组，非 dmz VPC 额外放通 dmz 业务子网网段以支持 ALB 跨 VPC 回源。

### 架构图

```mermaid
flowchart LR
    classDef main fill:#EAF4FF,stroke:#5B8FF9,color:#0D47A1;
    classDef tcc fill:#DFF2FF,stroke:#409EFF,color:#0D47A1;
    classDef note fill:#FFFDE7,stroke:#FBC02D,color:#5D4037;

    inet["🌐 Internet<br/>外部用户/调用方"]:::tcc

    subgraph Hub["DMZ Hub - 公网出入口枢纽"]
        direction TB
        bp["📦 vpc_bandwidth_package<br/>shared 共享带宽包"]:::main
        nat_eip["🔢 vpc_eip<br/>NAT 出向 EIP"]:::main
        alb_eip["🔢 ALB 内置 EIP x2<br/>每 AZ 1 个，由 eip_billing_config 创建"]:::main
        nat["🚪 natgateway_ngw<br/>公网 NAT 网关"]:::main
        alb["🛡️ alb_load_balancer<br/>公网 ALB 多 AZ"]:::main

        nat -.-> nat_eip
        alb -.-> alb_eip
        nat_eip -.-> bp
        alb_eip -.-> bp
    end

    subgraph DMZVPC["dmz VPC - 172.16.0.0/16"]
        direction TB
        dmz_vpc["🌐 vpc_vpc<br/>dmz VPC"]:::main
        dmz_subnets["🪟 vpc_subnet x4<br/>2 业务 + 2 TR 子网"]:::main
        dmz_rt["🧭 vpc_route_table<br/>0.0.0.0/0 NatGW<br/>dev/prd CIDR TR"]:::main
        sg_dmz["🔒 vpc_security_group<br/>dmz 安全组"]:::main

        dmz_vpc --> dmz_subnets --> dmz_rt
        dmz_subnets -.-> sg_dmz
    end

    tr["🚦 transitrouter_transit_router<br/>中转路由器"]:::main

    subgraph DevVPC["dev VPC - 172.17.0.0/16"]
        direction TB
        dev_vpc["🌐 vpc_vpc<br/>dev VPC"]:::main
        dev_subnets["🪟 vpc_subnet x4<br/>2 业务 + 2 TR 子网"]:::main
        dev_rt["🧭 vpc_route_table<br/>0.0.0.0/0 + RFC1918 TR"]:::main
        dev_ecs["💻 ecs_instance x2<br/>dev 工作负载"]:::main
        sg_dev["🔒 vpc_security_group<br/>dev 安全组"]:::main

        dev_vpc --> dev_subnets --> dev_rt
        dev_subnets --> dev_ecs
        dev_ecs -.-> sg_dev
    end

    subgraph PrdVPC["prd VPC - 172.18.0.0/16"]
        direction TB
        prd_vpc["🌐 vpc_vpc<br/>prd VPC"]:::main
        prd_subnets["🪟 vpc_subnet x4<br/>2 业务 + 2 TR 子网"]:::main
        prd_rt["🧭 vpc_route_table<br/>RFC1918 TR"]:::main
        prd_ecs["💻 ecs_instance x2<br/>prd 工作负载"]:::main
        sg_prd["🔒 vpc_security_group<br/>含 ALB 回源放通"]:::main

        prd_vpc --> prd_subnets --> prd_rt
        prd_subnets --> prd_ecs
        prd_ecs -.-> sg_prd
    end

    inet -->|"入向 HTTP/HTTPS"| alb
    alb --> tr
    tr --> prd_ecs

    dev_ecs --> tr
    tr --> nat
    nat --> inet

    dmz_vpc -.-> tr
    dev_vpc -.-> tr
    prd_vpc -.-> tr

    note_tr["📌 TR 自定义路由表<br/>3 VPC association + propagation<br/>各 VPC CIDR 显式传播<br/>0.0.0.0/0 静态路由 → dmz Attachment"]:::note
    tr -.-> note_tr

    note_alb["📌 ALB 入向<br/>type=public 多 AZ<br/>IP 类后端 prd ECS<br/>HTTP 健康检查 GET /"]:::note
    alb -.-> note_alb

    note_nat["📌 NAT 出向<br/>spec=Small<br/>SNAT 源 dev CIDR<br/>EIP 直挂 NAT instance_type=Nat"]:::note
    nat -.-> note_nat

    note_bp["📌 带宽包<br/>聚合 NAT EIP + 2 个 ALB EIP<br/>billing_type=2 BGP"]:::note
    bp -.-> note_bp
```

## 3. IaC 设计

### 3.1 资源清单

本工程实际创建的资源（**云资源全部使用 volcenginecc Provider**），按一次默认配置的 `terraform apply` 创建的真实数量统计：

| Terraform 资源                                 | 数量     | 用途                                                                                                                 |
| -------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------ |
| volcenginecc\_transitrouter\_transit\_router | 1      | 中央 TR 实例，三 VPC 路由互通枢纽                                                                                              |
| volcenginecc\_transitrouter\_vpc\_attachment | 3      | TR ↔ VPC 连接，每 VPC 一个，含跨 AZ attach\_points                                                                          |
| volcenginecc\_transitrouter\_transit\_router\_route\_table | 1 | TR 自定义路由表，承载三 VPC 的关联与传播（打通跨 VPC 转发的关键）                                                          |
| volcenginecc\_transitrouter\_transit\_router\_route\_table\_association | 3 | 每个 VPC Attachment 关联到 TR 自定义路由表                                                             |
| volcenginecc\_transitrouter\_route\_table\_propagation | 3 | 每个 VPC 的 CIDR 传播进 TR 路由表（替代不生效的 auto\_publish，去程/回程明细路由来源）                          |
| volcenginecc\_transitrouter\_transit\_router\_route\_entry | 1 | TR 静态默认路由 0.0.0.0/0 → dmz Attachment，供 dev VPC 经 dmz NAT 统一出向                              |
| volcenginecc\_vpc\_vpc                       | 3      | dmz / dev / prd 三个业务 VPC                                                                                           |
| volcenginecc\_vpc\_subnet                    | 12     | 每 VPC 4 个子网（2 业务 + 2 TR），跨 AZ                                                                                      |
| volcenginecc\_vpc\_route\_table              | 3      | 三张自定义路由表均由根模块创建：dev/prd（RFC1918 → TR，dev 加 0.0.0.0/0 → TR）；dmz（0.0.0.0/0 → NatGW + dev/prd CIDR → TR） |
| volcenginecc\_vpc\_security\_group           | 3      | 每 VPC 默认安全组（基线 22/80/443 放通 + 非 dmz VPC 加 ALB 回源段）                                                                 |
| volcenginecc\_natgateway\_ngw                | 1      | dmz VPC 公网 NAT 网关，承载统一出向                                                                                           |
| volcenginecc\_natgateway\_snatentry          | 1      | dev VPC CIDR → NAT EIP 的 SNAT 规则                                                                                   |
| volcenginecc\_vpc\_eip                       | 1      | NAT 出向专用 EIP（`instance_type=Nat` 直接绑定到 NAT，无需独立 associate 资源）                                                      |
| volcenginecc\_vpc\_bandwidth\_package        | 1      | 共享带宽包：聚合 1 个 NAT EIP 与 2 个跨 AZ 的 ALB 自动创建 EIP                                                                       |
| volcenginecc\_alb\_load\_balancer            | 1      | dmz VPC 内多 AZ 公网 ALB；EIP 由 `eip_billing_config` 自动创建（不是独立 resource）                                                |
| volcenginecc\_alb\_server\_group             | 1      | ALB 后端服务器组（IP 类，绑定 prd ECS 私网 IP）                                                                                  |
| volcenginecc\_alb\_listener                  | 1      | ALB HTTP:80 监听器，关联默认服务器组                                                                                           |
| volcenginecc\_ecs\_instance                  | 4      | dev × 2 + prd × 2，跨业务子网 / AZ 部署                                                                                    |
| **云资源小计**                                   | **44** | 以上均为 volcenginecc Provider 管理                                                                                            |
| time\_sleep（hashicorp/time）                 | 7      | 仅设置 `destroy_duration` 的等待屏障：子网 1、TR Attachment 间隔 2、TR 组间 2、安全组 1、NAT 网关 1；不影响 apply 耗时                          |
| **总计**                                       | **51** | 44 个云资源 + 7 个 `time_sleep`                                                                                       |

### 3.2 工程结构

工程采用模块化设计，根模块负责编排与所有涉及 Transit Router 的资源，子模块封装单个 VPC 的网络底座：

```text
dmz-vpc/
├── main.tf                  # 根模块编排：TR + TR 自定义路由表(association/propagation/静态默认路由) + 3 TR Attachment(串行) + 3 VPC 模块 + 全部 VPC 路由表 + 安全组 + NAT/ALB/ECS + 带宽包
├── variables.tf             # 全局输入变量（含 vpcs 拓扑、TR/NAT/ALB/ECS 配置、安全组规则）
├── outputs.tf               # 关键资源输出（TR ID、VPC ID、EIP、ALB DNS、ECS IP 等）
├── providers.tf             # volcenginecc Provider 配置（仅根模块，region 来自变量）
├── versions.tf              # Terraform >= 1.4.0，Provider 版本约束：volcenginecc ~> 0.0.70、time ~> 0.9
├── locals.tf                # 公共标签 + dmz/dev/prd key 常量
├── terraform.tfvars         # 默认变量值（已含 cn-beijing Rocky Linux 9.5 镜像 ID）
├── README.md                # 本文档
└── modules/
    ├── tr-vpc/              # 单 VPC 模块：仅创建 VPC + 业务/TR 子网，并输出 TR 连接点 tr_attach_points
    │                        # （TR Attachment 与 VPC 路由表统一在根模块创建，以便串行化并打破依赖环）
    ├── nat/                 # NAT 模块：NAT 网关 + 直挂 EIP + SNAT 规则
    ├── alb/                 # ALB 模块：ALB（每 AZ 自动 EIP）+ 服务器组 + 监听器
    └── ecs/                 # ECS 模块：多 AZ ECS 实例（含 lifecycle.ignore_changes 抑制 Provider drift）
```

说明：

- VPC 数量由 `vpcs` 控制，必须包含 `dmz` / `dev` / `prd` 三个 key（变量校验）；每 VPC 子网数量由 `business_subnet_cidrs` / `tr_subnet_cidrs` 与 `zones` 控制。
- ECS 数量由 `ecs_config.instances_per_subnet` 控制（dev / prd 每业务子网各若干台），设为 `0` 可只创建网络底座。
- 涉及 Transit Router 的资源（Attachment、association、propagation、TR 路由表、静态默认路由）均在根模块按固定顺序 `dmz → dev → prd` **串行**创建。

### 3.3 核心代码片段

根模块编排（节选）：

```hcl
# 中转路由器 – 中央路由枢纽
resource "volcenginecc_transitrouter_transit_router" "main" {
  transit_router_name = coalesce(var.tr_config.name, "${var.name_prefix}-tr")
  asn                 = var.tr_config.asn
  project_name        = var.project_name
  tags                = local.common_tags_list
}

# 三 VPC（dmz / dev / prd）批量创建网络底座（仅 VPC + 子网）
module "vpcs" {
  source   = "./modules/tr-vpc"
  for_each = var.vpcs

  vpc_name              = "${var.name_prefix}-${each.key}"
  cidr_block            = each.value.cidr_block
  business_subnet_cidrs = each.value.business_subnet_cidrs
  tr_subnet_cidrs       = each.value.tr_subnet_cidrs
  zones                 = var.zones
  tags                  = local.common_tags_list
}

# dmz 路由表：0.0.0.0/0 → NAT、dev/prd CIDR → TR（依赖 NAT 与 dmz Attachment）
resource "volcenginecc_vpc_route_table" "dmz" {
  vpc_id     = module.vpcs[local.dmz_key].vpc_id
  subnet_ids = module.vpcs[local.dmz_key].business_subnet_ids
  custom_route_entries = [for e in local.dmz_route_entries : {
    destination_cidr_block = e.destination_cidr_block
    next_hop_type          = e.next_hop_type
    next_hop_id            = e.next_hop_id
    description            = e.description
  }]
  depends_on = [volcenginecc_transitrouter_vpc_attachment.dmz]
}

# 共享带宽包：聚合 1 个 NAT EIP 与所有 AZ 的 ALB EIP
resource "volcenginecc_vpc_bandwidth_package" "shared" {
  bandwidth_package_name = "${var.name_prefix}-shared-bp"
  bandwidth              = var.shared_bandwidth_package_mbps
  billing_type           = 2
  isp                    = "BGP"
  protocol               = "IPv4"
  eip_addresses = concat(
    [{ allocation_id = module.nat.eip_id }],
    [for allocation_id in module.alb.alb_eip_allocation_ids : {
      allocation_id = allocation_id
    }],
  )
}
```

子模块 `modules/tr-vpc/main.tf` 只负责 VPC + 子网（TR Attachment 与路由表统一在根模块创建，以便串行化并打破依赖环）：

```hcl
resource "volcenginecc_vpc_vpc" "this" {
  vpc_name   = var.vpc_name
  cidr_block = var.cidr_block
}

resource "volcenginecc_vpc_subnet" "business" {
  for_each = local.business_subnets
  vpc_id   = volcenginecc_vpc_vpc.this.id
  ...
}

resource "volcenginecc_vpc_subnet" "tr" {
  for_each = local.tr_subnets
  vpc_id   = volcenginecc_vpc_vpc.this.id
  ...
}

# 供根模块创建 Attachment 使用的连接点（subnet_id + zone_id）
output "tr_attach_points" {
  value = [for s in volcenginecc_vpc_subnet.tr : { subnet_id = s.id, zone_id = s.zone_id }]
}
```

根模块 TR Attachment 串行链（关键修复，节选）。三个 Attachment 之间用仅销毁生效的 `time_sleep` 隔开：创建时仍为 `dmz → dev → prd` 串行，销毁时反向并在每两级之间等待 10 秒：

```hcl
# dmz Attachment（创建链起点）
resource "volcenginecc_transitrouter_vpc_attachment" "dmz" {
  transit_router_id = volcenginecc_transitrouter_transit_router.main.transit_router_id
  vpc_id            = module.vpcs["dmz"].vpc_id
  attach_points     = module.vpcs["dmz"].tr_attach_points
}

# 销毁时在 dev 删除后、dmz 删除前等待 10s
resource "time_sleep" "after_dmz_attachment" {
  destroy_duration = "10s"
  depends_on       = [volcenginecc_transitrouter_vpc_attachment.dmz]
}

resource "volcenginecc_transitrouter_vpc_attachment" "dev" {
  # ...
  attach_points = module.vpcs["dev"].tr_attach_points
  depends_on    = [time_sleep.after_dmz_attachment]
}

# 销毁时在 prd 删除后、dev 删除前等待 10s
resource "time_sleep" "after_dev_attachment" {
  destroy_duration = "10s"
  depends_on       = [volcenginecc_transitrouter_vpc_attachment.dev]
}

resource "volcenginecc_transitrouter_vpc_attachment" "prd" {
  # ...
  attach_points = module.vpcs["prd"].tr_attach_points
  depends_on    = [time_sleep.after_dev_attachment]
}
```

子模块 `modules/ecs/main.tf` 关键片段（含 Provider drift 抑制）：

```hcl
resource "volcenginecc_ecs_instance" "this" {
  for_each = local.instance_specs

  instance_name = each.key
  instance_type = var.instance_type
  zone_id       = each.value.zone_id

  image                     = { image_id = var.image_id }
  primary_network_interface = { subnet_id = each.value.subnet_id, security_group_ids = [var.security_group_id] }
  system_volume             = { size = var.system_volume_size, volume_type = var.system_volume_type, delete_with_instance = true }

  # volcenginecc Provider 已知问题：嵌套只读字段每次 plan 都标 (known after apply)
  lifecycle {
    ignore_changes = [
      image, primary_network_interface, system_volume,
      affinity_group_size, auto_pay, auto_renew, auto_renew_period,
      cpu_max_frequency, credit_specification, include_data_volumes,
      install_run_command_agent, period, period_unit,
    ]
  }
}
```

## 4. 使用说明

### 4.1 环境准备

**控制台操作与服务开通**（首次部署前需确认）：

- 在目标区域（默认 `cn-beijing`）开通 **VPC、中转路由器 TR、NAT 网关、应用型负载均衡 ALB、EIP、共享带宽包、ECS** 等服务。
- 首次使用 ALB 需在控制台完成服务关联角色授权，否则创建 ALB 会因缺少 `ServiceRoleForALB` 报错。
- 确认目标可用区（默认 `cn-beijing-a` / `cn-beijing-c`）下 ECS 规格、EIP 与带宽包库存可用。
- 确认账号 EIP、共享带宽包等资源配额充足（本工程默认创建 3 个 EIP：1 个 NAT EIP + 2 个跨 AZ 的 ALB EIP，以及 1 个共享带宽包）。

**执行账号权限准备**（最小权限原则）：

- 为执行 Terraform 的 IAM 账号授予 VPC、TransitRouter、NatGateway、ALB、EIP、BandwidthPackage、ECS 的创建 / 查询 / 更新 / 删除权限。
- 严禁使用具有全局管理员权限的 Root 账号 AK/SK 执行日常变更。

**本地环境**：

1. 安装 Terraform `>= 1.4.0`：
   ```bash
   terraform version
   ```
2. 配置火山引擎凭证（**严禁硬编码到代码**）：
   ```bash
   export VOLCENGINE_ACCESS_KEY="your_ak"
   export VOLCENGINE_SECRET_KEY="your_sk"
   export VOLCENGINE_REGION="cn-beijing"
   ```
3. （可选）配置网络镜像加速 Provider 下载，编辑 `~/.terraformrc`：
   ```hcl
   provider_installation {
     network_mirror {
       url     = "https://mirrors.volces.com/terraform/terraformcc/"
       include = ["registry.terraform.io/volcengine/volcenginecc"]
     }
     direct {
       exclude = ["registry.terraform.io/volcengine/volcenginecc"]
     }
   }
   ```

### 4.2 配置变量

敏感变量不要写入 ` terraform.tfvars` ，建议通过环境变量注入（ECS 登录密码在 `ecs_config` 对象内）：

```bash
export TF_VAR_ecs_config='{ image_id = "image-xxxx", password = "<placeholder>" }'
```

当前示例参数如下。未在 `terraform.tfvars` 中显式填写的参数沿用变量默认值。

| 参数 | 当前示例值 / 默认值 | 说明 |
| --- | --- | --- |
| `region` | `cn-beijing` | 部署地域 |
| `project_name` | `default` | 资源所属项目 |
| `name_prefix` | `dmz` | 资源名称前缀 |
| `common_tags` | `Project` / `Environment` / `Owner` / `ManagedBy` | 注入到支持标签的资源 |
| `zones` | `cn-beijing-a`、`cn-beijing-c` | 可用区列表（至少 2 个，用于多 AZ） |
| `vpcs` | dmz `172.16/16` / dev `172.17/16` / prd `172.18/16` | 三个 VPC 的 CIDR、业务子网、TR 子网及 `outbound` 开关；CIDR 需互不重叠 |
| `vpc_internal_route_cidrs` | `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` | 各 VPC 经 TR 互通的 RFC1918 网段 |
| `tr_config` | `asn = 64512` | 中转路由器名称 / 描述 / ASN |
| `nat_gateway_spec` | `Small` | dmz NAT 网关规格 |
| `nat_eip_bandwidth_mbps` | `5` | NAT 出向 EIP 带宽（Mbps） |
| `alb_eip_bandwidth_mbps` | `5` | ALB 内置 EIP 带宽（Mbps） |
| `shared_bandwidth_package_mbps` | 示例 `15`（变量默认 `10`） | 共享带宽包总带宽，需 ≥ 各 EIP 带宽之和 |
| `alb_config` | `IPv4` / `Standard` / `HTTP` / `80` / `/` | ALB IP 版本、版本、监听协议/端口、健康检查 URI |
| `ecs_config.image_id` | 示例公共镜像 ID | 必须替换为目标地域可用镜像；默认值为 cn-beijing Rocky Linux 9.5 |
| `ecs_config.instance_type` | `ecs.g3i.large` | ECS 规格 |
| `ecs_config.password` | 敏感，必须覆盖 | ECS 登录密码，建议用 `TF_VAR_ecs_config` 注入 |
| `ecs_config.system_volume_type` | `ESSD_PL0` | ECS 系统盘类型 |
| `ecs_config.system_volume_size` | `50` | ECS 系统盘容量（GB） |
| `ecs_config.instances_per_subnet` | `1` | dev / prd 每业务子网的 ECS 数量；设为 `0` 仅建网络底座 |
| `default_ingress_rules` | 放行 22 / 80 / 443 | 每 VPC 安全组的基线入站规则 |

### 4.3 一键部署

初始化与校验：

```bash
terraform init
terraform fmt -check -recursive
terraform validate
```

部署：

```bash
terraform plan -out tfplan
terraform apply tfplan
```

> ℹ️ 涉及 Transit Router 的资源已在代码中按 `dmz → dev → prd` 串行创建，**无需手动指定 `-parallelism=1`**，一次 `terraform apply` 即可稳定完成。

### 4.4 场景化部署示例

#### 场景 A：仅创建网络底座（不部署 ECS）

如果只想先把 TR + 三 VPC + NAT/ALB 拉起来，把 `ecs_config.instances_per_subnet` 设置为 `0`：

```hcl
ecs_config = {
  instance_type        = "ecs.g3i.large"
  image_id             = "image-yzpyj8j5sl4e0wax4krm"
  password             = "ReplaceMe@12345"
  instances_per_subnet = 0
}
```

#### 场景 B：dev/prd 双向出向

默认仅 dev VPC 走 NAT 出向。如果 prd VPC 也需要出向：

1. 把 `vpcs.prd.outbound` 改为 `true`；
2. 在 [main.tf](file:///opt/test-tf/terraform-volcenginecc-dmz-vpc/main.tf) 的 `module.nat.snat_source_cidrs` 增加 prd CIDR。

#### 场景 C：HTTPS 入向

将 `alb_config.listener_protocol` 改为 `HTTPS`、`listener_port` 改为 `443`，并在 [modules/alb/main.tf](file:///opt/test-tf/terraform-volcenginecc-dmz-vpc/modules/alb/main.tf) 的 `volcenginecc_alb_listener` 资源上增加 `certificate_source = "cert_center"` 与 `cert_center_certificate_id` 等参数（参考火山引擎 ALB 证书中心文档）。

> 关闭功能或减少数量会在下一次执行时**删除**相应资源，而非仅暂停服务。ECS 的规格、密码、镜像、主网卡和系统盘配置被生命周期规则忽略，修改这些参数不会自动更新已有实例，应先评估替换方案。

### 4.5 部署预期结果

`terraform apply` 成功后，默认（`instances_per_subnet = 1`）会创建 **51 个资源**（44 个云资源 + 7 个仅销毁生效的 `time_sleep`），核心可见结果如下：

- 1 个中转路由器 TR + 1 张 TR 自定义路由表（3 association + 3 propagation + 1 条 `0.0.0.0/0` 静态默认路由）。
- 3 个 VPC（dmz / dev / prd），每 VPC 4 个子网（2 业务 + 2 TR，跨 AZ）、1 个安全组、1 张 VPC 路由表 + 3 个 TR VPC Attachment。
- dmz VPC 内：1 个公网 NAT 网关 + 1 个 NAT EIP + 1 条 SNAT 规则；1 个多 AZ 公网 ALB（每 AZ 自带 1 个 EIP，共 2 个）+ 1 个 IP 类服务器组 + 1 个 HTTP:80 监听器。
- 1 个共享带宽包，聚合 1 个 NAT EIP 与 2 个 ALB EIP。
- dev × 2 + prd × 2 共 4 台 ECS。

通过 `terraform output` 查看关键输出：

```bash
terraform output
```

| 输出 | 说明 |
| --- | --- |
| `transit_router_id` | 中转路由器 TR ID |
| `transit_router_route_table_id` | TR 自定义路由表 ID |
| `vpc_ids` | dmz / dev / prd 三个 VPC ID 映射 |
| `vpc_route_table_ids` | 三个 VPC 的路由表 ID 映射 |
| `tr_attachment_ids` | 三个 VPC 的 TR Attachment ID 映射 |
| `security_group_ids` | 三个 VPC 的安全组 ID 映射 |
| `nat_gateway_id` / `nat_eip_address` | NAT 网关 ID 与出向公网 IP |
| `alb_id` / `alb_dns_name` | ALB ID 与 DNS 名称 |
| `alb_eip_address` / `alb_eip_addresses` | 第一个入向公网 IP 与全部可用区入向公网 IP 列表 |
| `shared_bandwidth_package_id` | 共享带宽包 ID |
| `dev_instance_ids` / `prd_instance_ids` | dev / prd ECS 实例 ID 映射 |
| `prd_backend_ips` | 注册到 ALB 后端的 prd ECS 私网 IP |

**业务连通性验证**（对齐集中式公网出入口设计目标）：

1. **入向（跨 VPC 后端）**：在 prd ECS 上启动 80 端口测试服务，逐一访问 `terraform output -json alb_eip_addresses` 中的每个公网 IP（对应各可用区），确认请求经 ALB → TR → prd ECS 返回预期内容；在 ALB 控制台确认跨 VPC 后端服务器组健康检查为正常。
2. **dev 统一出向**：登录 dev ECS 访问公网地址（如 `curl ifconfig.me`），确认能正常出网，且出口公网 IP 为 `nat_eip_address`（即经 dmz NAT 统一出向）。
3. **prd 默认不出向**：登录 prd ECS 执行相同访问，确认其默认**不能**直接出网（prd `outbound=false`，未注册 SNAT）。
4. **路由完整性**：核对 TR 自定义路由表与 dmz/dev/prd 三张 VPC 路由表，确认去程与回程路径完整，且不存在绕过 dmz 的公网默认路由。

### 4.6 TR 跨 VPC 路由（已全自动，无需手动）

本方案的 TR 跨 VPC 路由**已全部由 Terraform 声明式管理**，`terraform apply` 完成后即打通，**无需任何手动补路由**：

- 三个 VPC Attachment 通过 **association** 关联到 TR 自定义路由表；
- 三个 VPC 的 CIDR 通过 **propagation** 传播进该路由表，形成去程（dmz→prd）与回程（prd→dmz）明细路由，ALB 跨 VPC 后端与健康检查因此可达；
- 一条 **静态默认路由** `0.0.0.0/0 → dmz Attachment` 用于 dev VPC 经 dmz NAT 统一出向。

可用如下命令核验 TR / VPC 路由表（无需登录控制台）：

```bash
terraform output transit_router_route_table_id     # TR 自定义路由表 ID
terraform output vpc_route_table_ids               # dmz/dev/prd 三张 VPC 路由表 ID
terraform show -json | ...                          # 解析 custom_route_entries / propagation / association 状态
```



### 4.7 销毁资源

```bash
terraform destroy -auto-approve
```

> ℹ️ 创建侧的 TR 操作已在代码中串行化。所有 `time_sleep` 均只设置 `destroy_duration`，不会拖慢 apply。TR 销毁链为「assoc/propagation 删完 → 等 10s → 删 TR 路由表 → 等 10s → 删 prd Attachment → 等 10s → 删 dev Attachment → 等 10s → 删 dmz Attachment」，给共享状态机留出逐级收敛时间。因此一般无需 `-parallelism=1`；若仍偶发 `InvalidStatus`，可追加 `-parallelism=1` 后重跑：
>
> ```bash
> terraform destroy -auto-approve -parallelism=1
> ```

> ℹ️ ECS 模块与安全组之间还设有一个仅销毁生效的 30 秒等待屏障。销毁时 ECS 删除完成后会等待主网卡（ENI）状态收敛，再删除安全组，避免 `InvalidEni.InvalidStatus`。
>
> ℹ️ NAT 销毁链为「SNAT → NAT EIP → 等 30s → NAT Gateway」。ALB、NAT、ECS、VPC 路由表和 TR Attachment 全部删除后，还会统一等待 30 秒再删除业务子网与 TR 子网，避免托管 ENI、主网卡或路由表关联尚未清理时触发 `InvalidSubnet.InUse`。
>
> ⚠️ Terraform 会并行执行互不依赖的销毁分支，固定等待的最长关键路径约 70 秒，不包含各云资源 API 自身耗时。务必先把 ALB 上的业务流量切走再 destroy。

> ⚠️ **`InvalidVpc.InUse`** **处理**：火山云每个 VPC 创建时会自动生成 1 个默认安全组 + 1 个默认路由表，它们是系统资源，通常随 VPC 删除自动回收，**不需要也不应手动删除**。若 destroy 报 `InvalidVpc.InUse: ... dependent resource of a security group / route table`，一般说明 VPC 中仍残留 Terraform 未成功删除或未纳管的**自定义（非默认）**安全组、路由表或其关联 ENI。处理方式：
>
> 1. 用 `data "volcenginecc_vpc_vpc"` 查询 `security_group_ids` / `route_table_ids`，区分默认资源与自定义资源；
> 2. 在控制台删除残留的**自定义（非默认）**安全组与路由表；删除安全组前先确认其关联 ENI 已释放（参见 `InvalidEni.InvalidStatus`）；
> 3. 若希望用 Terraform 回收残留的自定义资源，可在临时工程中 `terraform import` 后再 `terraform destroy`；**不要 import 默认系统资源**；
> 4. 重新执行 `terraform destroy`，默认安全组与路由表会随 VPC 一并回收。
>
> <br />

## 5. 总结

本方案的主要优势：

- **标准化交付**：通过 Terraform 统一创建网络、路由、公网出向、公网入向、带宽聚合与工作负载资源，一键 `terraform apply` 即可完成集中式公网出入口环境的交付。
- **集中治理**：跨 VPC 路由集中在 TR 自定义路由表（association + propagation + 静态默认路由，声明式全托管），安全组规则集中在根模块编排，NAT EIP 与各可用区 ALB EIP 集中纳入共享带宽包，符合 Landing Zone“集中式治理”的最佳实践。
- **稳定创建**：所有涉及 Transit Router 的资源在根模块按 `dmz → dev → prd` 串行创建，规避 TR 并发操作导致的 `InvalidStatus`，无需手动 `-parallelism=1`；dmz / dev / prd 的 VPC 路由表统一在根模块创建以打破模块与 Attachment 之间的依赖环。
- **多 AZ 高可用**：所有子网（业务子网 + TR 子网）默认跨 AZ 分布，ALB 跨 AZ 部署，ECS 跨子网创建，原生支持高可用。
- **模块化复用**：按 `tr-vpc`（网络底座）/ `nat`（出向）/ `alb`（入向）/ `ecs`（工作负载）拆分模块，便于按需组合与独立升级。

未来可继续扩展：

- 接入 **`volcenginecc_apig_gateway`** 替换 ALB，提供更完整的网关能力（认证、限流、灰度）。
- 集成 **`volcenginecc_waf_domain`** 做入向 WAF 防护，统一在 dmz VPC 落地。
- 接入 **`volcenginecc_iam_role`** + 最小权限策略，让 Terraform 执行账号仅持有必要权限。
- 启用 **`volcenginecc_vpc_flow_log`** 做 TR / VPC 流量审计，与 CLS / Prometheus 联动。
- 接入远端 Backend 管理 Terraform State，支持团队协作与 CI/CD 流水线。

