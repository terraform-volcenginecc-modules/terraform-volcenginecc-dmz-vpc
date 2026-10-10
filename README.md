# DMZ-VPC 统一公网出入口

部署一套集中式的公网出入口，覆盖网络、路由、公网出向（NAT）、公网入向（ALB）、带宽聚合与工作负载等核心资源，通过中转路由器 Transit Router 将三个 VPC 组成星型拓扑，把公网出向收敛到 dmz NAT、公网入向收敛到 dmz 公网 ALB，并将 NAT EIP 与各可用区的 ALB EIP 纳入共享带宽包。

## 1. 业务背景

随着企业上云，多业务线、多环境的 VPC 数量快速膨胀，常见的“每个 VPC 各自挂 EIP / NAT”做法通常会遇到以下问题：

- **公网出向碎片化**：每个 VPC 独立分配 NAT + EIP，出向 IP 散乱难治理、白名单维护成本高、带宽难以聚合议价。
- **公网入向暴露面大**：每个 VPC 都对外开放 ALB/SLB，安全审计与 WAF 部署点分散，攻击面成倍增长。
- **跨 VPC 互通混乱**：业务流量在多个 VPC 间走 VPN / 对等连接拼接，路由策略难以集中管理，故障排查链路长。
- **扩展和回收成本高**：手工搭建多 VPC 互联环境易出错，验证结束后也需要可靠销毁资源，降低闲置成本。

本方案通过 Terraform 把上述基础设施标准化、模块化，落地一套集中式 DMZ-VPC，帮助用户快速完成统一公网出入口环境的交付。

## 2. 方案概述

整体采用“公网出入口枢纽”架构：

- **接入层（入向）**：dmz VPC 内的公网 ALB 承接互联网 HTTP/HTTPS 流量，经 TR 反向转发到 prd 工作负载。
- **出向层**：dmz VPC 内的公网 NAT 网关 + 单一 EIP 承载统一出向，dev VPC 默认路由经 TR 收敛到此出向。
- **路由枢纽**：中转路由器 Transit Router 作为中央路由枢纽，dmz / dev / prd 三 VPC 各挂一个 VPC Attachment，专用 TR 子网作为连接点。
- **工作负载层**：dev / prd 两个业务 VPC 跨可用区部署 ECS，dmz VPC 仅承载出入口组件。
- **带宽聚合**：1 个 NAT EIP 与每个可用区各 1 个的 ALB 内置 EIP 纳入同一共享带宽包，集中议价、计费、限速。
- **安全控制**：每 VPC 独立安全组，非 dmz VPC 额外放通 dmz 业务子网网段以支持 ALB 跨 VPC 回源。
- **生命周期**：涉及 Transit Router 的资源按 `dmz → dev → prd` 严格串行创建；资源销毁阶段通过仅销毁生效的 `time_sleep` 等待屏障，给 TR、NAT、子网、安全组等共享状态机留出收敛时间。

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

> 架构图阅读说明：子网数量由 `vpcs[*].business_subnet_cidrs` 与 `tr_subnet_cidrs` 列表长度决定；ECS 数量由 `ecs_config.instances_per_subnet × 业务子网数 × 2 (dev+prd)` 计算；ALB 内置 EIP 数量与业务子网数量（即跨 AZ 数量）一致。

## 3. IaC 设计

### 3.1 资源清单

按变量当前默认值与 `terraform.tfvars` 示例值计算（`instances_per_subnet = 1`，每 VPC 2 个业务子网、2 个 TR 子网，跨 2 个可用区），一次 `terraform apply` 共创建 44 个云资源：

| Terraform 资源 | 数量 | 用途 |
| --- | --- | --- |
| `volcenginecc_transitrouter_transit_router` | 1 | 中央 TR 实例，三 VPC 路由互通枢纽 |
| `volcenginecc_transitrouter_vpc_attachment` | 3 | TR ↔ VPC 连接，每 VPC 一个，含跨 AZ `attach_points` |
| `volcenginecc_transitrouter_transit_router_route_table` | 1 | TR 自定义路由表，承载三 VPC 的关联与传播 |
| `volcenginecc_transitrouter_transit_router_route_table_association` | 3 | 每个 VPC Attachment 关联到 TR 自定义路由表 |
| `volcenginecc_transitrouter_route_table_propagation` | 3 | 每个 VPC 的 CIDR 传播进 TR 路由表 |
| `volcenginecc_transitrouter_transit_router_route_entry` | 1 | TR 静态默认路由 `0.0.0.0/0 → dmz Attachment` |
| `volcenginecc_vpc_vpc` | 3 | dmz / dev / prd 三个业务 VPC |
| `volcenginecc_vpc_subnet` | 12 | 每 VPC 4 个子网（2 业务 + 2 TR），跨 AZ |
| `volcenginecc_vpc_route_table` | 3 | dmz（0.0.0.0/0 → NatGW + dev/prd CIDR → TR）、dev（RFC1918 + 0.0.0.0/0 → TR）、prd（RFC1918 → TR） |
| `volcenginecc_vpc_security_group` | 3 | 每 VPC 默认安全组（基线 22 / 80 / 443，非 dmz VPC 额外放通 dmz 业务子网回源） |
| `volcenginecc_natgateway_ngw` | 1 | dmz VPC 公网 NAT 网关，承载统一出向 |
| `volcenginecc_natgateway_snatentry` | 1 | dev VPC CIDR → NAT EIP 的 SNAT 规则（按 `snat_source_cidrs` 条数创建） |
| `volcenginecc_vpc_eip` | 1 | NAT 出向专用 EIP（`instance_type = Nat` 直接绑定到 NAT） |
| `volcenginecc_vpc_bandwidth_package` | 1 | 共享带宽包：聚合 1 个 NAT EIP 与各可用区的 ALB EIP |
| `volcenginecc_alb_load_balancer` | 1 | dmz VPC 多 AZ 公网 ALB；EIP 由 `eip_billing_config` 自动创建 |
| `volcenginecc_alb_server_group` | 1 | ALB 后端服务器组（IP 类，绑定 prd ECS 私网 IP） |
| `volcenginecc_alb_listener` | 1 | ALB HTTP:80 监听器，关联默认服务器组 |
| `volcenginecc_ecs_instance` | 4 | dev × 2 + prd × 2，跨业务子网 / AZ 部署 |
| **云资源合计** | **44** | 均由 `volcenginecc` Provider 管理 |

补充说明：

- 条件行为：当 `vpcs[*].outbound = false` 时，对应 VPC 路由表不添加 `0.0.0.0/0` 条目。默认仅 dev VPC 开启。
- 数据源 `data.volcenginecc_alb_load_balancer` 只读查询 ALB 的多可用区 EIP，不创建资源。
- 若 `ecs_config.instances_per_subnet = 0`，则不创建任何 ECS，云资源总数会相应减少 4 个。
- `time_sleep` 仅在销毁阶段生效，不影响 `terraform apply` 耗时，也不创建云端资源。

### 3.2 工程结构

```text
terraform-volcenginecc-dmz-vpc/
├── main.tf                  # 根模块编排：TR、TR 路由表（association/propagation/静态默认路由）、3 TR Attachment 串行链、三 VPC 模块、全部 VPC 路由表、安全组、NAT/ALB/ECS 模块、共享带宽包、销毁屏障
├── variables.tf             # 全局输入变量（vpcs 拓扑、TR/NAT/ALB/ECS 配置、安全组规则）
├── outputs.tf               # 关键资源输出（TR、VPC、EIP、ALB DNS、ECS IP 等）
├── providers.tf             # volcenginecc Provider 配置（仅根模块，region 来自变量）
├── versions.tf              # Terraform ≥ 1.4.0；Provider：volcenginecc ~> 0.0.70、hashicorp/time ~> 0.9
├── locals.tf                # 公共标签 + dmz/dev/prd 的 key 常量
├── terraform.tfvars         # 示例变量值（含 cn-beijing Rocky Linux 9.5 公共镜像 ID）
├── README.md                # 本文档
└── modules/
    ├── tr-vpc/              # 单 VPC 网络底座：VPC + 业务子网 + TR 子网，输出 tr_attach_points
    ├── nat/                 # NAT 网关 + 直挂 EIP + SNAT 规则 + NAT 销毁等待
    ├── alb/                 # 多 AZ 公网 ALB（含自动 EIP）+ IP 类服务器组 + HTTP 监听器
    └── ecs/                 # 多 AZ ECS 实例（含 lifecycle.ignore_changes 抑制 Provider drift）
```

模块边界与依赖：

- TR Attachment 与所有 VPC 路由表统一放在根模块创建，避免 `module.vpcs → attachment → module.vpcs` 的依赖环，并实现严格串行。
- `modules/tr-vpc` 只负责 VPC + 子网，不感知 TR Attachment，可在多工程间复用。
- `modules/nat`、`modules/alb`、`modules/ecs` 分别封装出向、入向、工作负载，可通过根模块变量按需裁剪或替换。

### 3.3 核心代码示例

TR Attachment 串行链（创建按 `dmz → dev → prd` 顺序；销毁时通过仅生效于销毁的 `time_sleep` 等待）：

```hcl
resource "volcenginecc_transitrouter_vpc_attachment" "dmz" {
  transit_router_id = volcenginecc_transitrouter_transit_router.main.transit_router_id
  vpc_id            = module.vpcs["dmz"].vpc_id
  attach_points     = module.vpcs["dmz"].tr_attach_points
}

resource "time_sleep" "after_dmz_attachment" {
  destroy_duration = "10s"
  depends_on       = [volcenginecc_transitrouter_vpc_attachment.dmz]
}

resource "volcenginecc_transitrouter_vpc_attachment" "dev" {
  attach_points = module.vpcs["dev"].tr_attach_points
  depends_on    = [time_sleep.after_dmz_attachment]
}

resource "time_sleep" "after_dev_attachment" {
  destroy_duration = "10s"
  depends_on       = [volcenginecc_transitrouter_vpc_attachment.dev]
}

resource "volcenginecc_transitrouter_vpc_attachment" "prd" {
  attach_points = module.vpcs["prd"].tr_attach_points
  depends_on    = [time_sleep.after_dev_attachment]
}
```

共享带宽包聚合所有 NAT EIP 与各可用区 ALB EIP：

```hcl
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

## 4. 使用说明

本工程支持通过 InfraManager 在云上一键部署或下载模板在本地运行。推荐使用云上部署方式，无需自行准备 Terraform 运行环境，只需在平台填写参数即可完成资源创建和托管。

### 4.1 云上部署

InfraManager 是火山引擎提供的 Terraform 托管工作台，更多产品介绍参见 [InfraManager 产品介绍](https://docs.volcengine.com/docs/infrastructure-management/product-introduction?lang=zh)。

#### 4.1.1 准备权限

本工程使用 `volcenginecc` 与 `hashicorp/time` Provider。请为执行账号准备以下火山引擎服务的全生命周期权限（创建 / 查询 / 更新 / 删除），遵循最小权限原则，避免直接使用主账号或全局管理员：

- **VPC**：VPC、子网、路由表、路由条目、安全组、EIP、共享带宽包。
- **Transit Router**：TR 实例、VPC Attachment、路由表、关联（Association）、传播（Propagation）、静态路由条目。
- **NAT 网关**：NAT 实例、SNAT 规则。
- **ALB**：负载均衡实例、服务器组、监听器；`volcenginecc_alb_load_balancer` 数据源需要只读查询权限。
- **ECS**：实例、系统盘。
- **标签**：以上资源的标签读写能力。
- **服务关联角色**：首次使用 ALB 需在控制台授权 `ServiceRoleForALB`，否则创建 ALB 会失败。

#### 4.1.2 选择模板

打开 [InfraManager 控制台](https://console.volcengine.com/iac)，进入 **模板管理 > 公开模板**，搜索“DMZ-VPC 统一公网出入口”。

#### 4.1.3 创建资源栈

选择模板并点击 **创建资源栈**，根据实际需求填写资源栈信息和模板参数。重点确认 `region`、`zones`、`vpcs`、`ecs_config` 等参数，并在凭证中注入访问密钥。创建并检查执行计划，确认变更符合预期（示例默认预期新增约 51 个资源，其中 44 个云资源 + 7 个仅销毁生效的 `time_sleep`）后，点击 **执行部署**。

#### 4.1.4 部署验证

在资源栈详情页查看部署状态为“成功”，再查看模板输出，确认下列关键字段：

| 输出 | 用途 |
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

在资源栈详情页的 **资源** 页签可以查看全部云资源的类型、名称与状态。按默认参数，典型结果为 1 个 TR、1 张 TR 自定义路由表、3 个 VPC、12 个子网、3 张 VPC 路由表、3 个安全组、1 个 NAT 网关 + 1 条 SNAT、1 个 ALB + 1 个服务器组 + 1 个监听器、1 个共享带宽包、以及 4 台 ECS。

### 4.2 本地部署

您也可以下载本工程模板在本地运行，需要按照下述步骤操作。

#### 4.2.1 环境准备

**基础环境**：

- 安装 Terraform `>= 1.4.0`，可执行 `terraform version` 校验。
- 本地可访问火山引擎 OpenAPI；如需加速 Provider 下载，可在 `~/.terraformrc` 中配置镜像：

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

**服务与配额**：

- 在目标地域开通 VPC、Transit Router、NAT 网关、ALB、EIP、共享带宽包、ECS 等服务。
- 首次使用 ALB 需在控制台授权 `ServiceRoleForALB`。
- 确认 `zones` 列表中的可用区下 ECS 规格、EIP、共享带宽包库存充足。
- 默认示例会创建 3 个 EIP（1 个 NAT + 2 个 ALB 内置）与 1 个共享带宽包，请提前核对账号 EIP、带宽包、ECS 配额。

**凭证注入**（推荐环境变量，不要写入代码或 `tfvars`）：

```bash
export VOLCENGINE_ACCESS_KEY="your_access_key"
export VOLCENGINE_SECRET_KEY="your_secret_key"
export VOLCENGINE_REGION="cn-beijing"
```

**敏感业务变量**：`ecs_config.password` 为敏感字段，建议通过环境变量注入，不要落到 `terraform.tfvars`：

```bash
export TF_VAR_ecs_config='{ image_id = "image-xxxx", password = "<placeholder>" }'
```

**重点参数**（变量默认值 vs 当前 `terraform.tfvars` 示例值）：

| 参数 | 变量默认值 | `terraform.tfvars` 示例值 | 说明 |
| --- | --- | --- | --- |
| `region` | `cn-beijing` | `cn-beijing` | 部署地域 |
| `project_name` | `default` | `default` | 资源所属项目 |
| `name_prefix` | `dmz` | `dmz` | 资源名称前缀 |
| `zones` | `["cn-beijing-a", "cn-beijing-b"]` | `["cn-beijing-a", "cn-beijing-c"]` | 可用区列表（至少 2 个，用于多 AZ） |
| `vpcs` | dmz `172.16/16` / dev `172.17/16` / prd `172.18/16` | 同默认 | 三个 VPC 的 CIDR、业务子网、TR 子网及 `outbound` 开关；CIDR 需互不重叠 |
| `vpc_internal_route_cidrs` | `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` | 同默认 | 各 VPC 经 TR 互通的 RFC1918 网段 |
| `tr_config` | `asn = 64512` | 同默认 | 中转路由器名称 / 描述 / ASN |
| `nat_gateway_spec` | `Small` | `Small` | dmz NAT 网关规格 |
| `nat_eip_bandwidth_mbps` | `5` | `5` | NAT 出向 EIP 带宽（Mbps） |
| `alb_eip_bandwidth_mbps` | `5` | `5` | ALB 内置 EIP 带宽（Mbps） |
| `shared_bandwidth_package_mbps` | `10` | `15` | 共享带宽包总带宽，需 ≥ 各 EIP 带宽之和 |
| `alb_config` | `IPv4` / `Standard` / `HTTP` / `80` / `/` | 同默认 | ALB IP 版本、版本、监听协议/端口、健康检查 URI |
| `ecs_config.image_id` | 无默认，必填 | `image-yzpyj8j5sl4e0wax4krm`（cn-beijing Rocky Linux 9.5） | 必须替换为目标地域可用镜像 |
| `ecs_config.instance_type` | `ecs.g3i.large` | `ecs.g3i.large` | ECS 规格 |
| `ecs_config.password` | 无默认，必填 | 占位 `ReplaceMe@12345`，**部署前必须覆盖** | ECS 登录密码；敏感字段，建议 `TF_VAR_ecs_config` 注入 |
| `ecs_config.system_volume_type` | `ESSD_PL0` | `ESSD_PL0` | ECS 系统盘类型 |
| `ecs_config.system_volume_size` | `50` | `50` | ECS 系统盘容量（GB） |
| `ecs_config.instances_per_subnet` | `1` | `1` | dev / prd 每业务子网的 ECS 数量；设为 `0` 仅建网络底座 |
| `default_ingress_rules` | 放行 22 / 80 / 443（源 `0.0.0.0/0`） | 同默认 | 每 VPC 安全组的基线入站规则（生产环境建议收敛 SSH 源网段） |
| `common_tags` | `Project` / `Environment` / `ManagedBy` | 增加 `Owner` | 注入到支持标签的资源 |

#### 4.2.2 场景化部署示例

初始化与校验：

```bash
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out tfplan
```

执行部署：

```bash
terraform apply tfplan
```

> 涉及 Transit Router 的资源已在代码中按 `dmz → dev → prd` 串行创建，无需手动指定 `-parallelism=1`。

**场景 A：仅创建网络底座（不部署 ECS）**。把 `ecs_config.instances_per_subnet` 设为 `0`，`terraform apply` 会跳过 dev / prd 的 4 台 ECS，但保留 TR、NAT、ALB、共享带宽包等出入口资源。再次将该参数设回正数并 `terraform apply`，会按新值补建 ECS。

**场景 B：dev / prd 双向出向**。将 `vpcs.prd.outbound` 改为 `true`，prd VPC 路由表会新增 `0.0.0.0/0 → TR` 条目；需要让 prd 真正出网，还要在 `module "nat"` 的 `snat_source_cidrs` 中追加 prd VPC CIDR，`terraform apply` 后 NAT 会新增一条 SNAT 规则。

**场景 C：HTTPS 入向**。把 `alb_config.listener_protocol` 改为 `HTTPS`、`listener_port` 改为 `443`，并在 `modules/alb/main.tf` 的 `volcenginecc_alb_listener` 上追加 `certificate_source = "cert_center"` 与 `cert_center_certificate_id` 等参数（参考火山引擎 ALB 证书中心文档）。`terraform apply` 会原地更新监听器。

> 减少 `vpcs` map 中的 VPC、`business_subnet_cidrs` 中的子网，或减少 ALB 的 `backend_ips` 数量，会在下一次 `terraform apply` 时**删除**相应资源，而非仅停用。ECS 的规格、密码、镜像、主网卡和系统盘配置被 `lifecycle.ignore_changes` 忽略，修改这些参数不会自动更新已有实例，应先评估替换方案。

#### 4.2.3 部署预期结果

按默认 `instances_per_subnet = 1` 执行，`terraform apply` 预期新增 44 个云资源 + 7 个仅销毁生效的 `time_sleep`：

- 1 个中转路由器 TR + 1 张 TR 自定义路由表（3 条 association + 3 条 propagation + 1 条 `0.0.0.0/0` 静态默认路由）。
- 3 个 VPC（dmz / dev / prd），每 VPC 4 个子网（2 业务 + 2 TR，跨 AZ）、1 个安全组、1 张 VPC 路由表 + 3 个 TR VPC Attachment。
- dmz VPC 内：1 个公网 NAT 网关 + 1 个 NAT EIP + 1 条 SNAT 规则；1 个多 AZ 公网 ALB（每 AZ 自带 1 个 EIP，共 2 个）+ 1 个 IP 类服务器组 + 1 个 HTTP:80 监听器。
- 1 个共享带宽包，聚合 1 个 NAT EIP 与 2 个 ALB EIP。
- dev × 2 + prd × 2 共 4 台 ECS。

通过以下命令查看输出：

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

#### 4.2.4 部署后简易验证

部署完成后，可在控制台与命令行执行以下几项简易检查，确认集中式出入口按预期工作：

1. **共享带宽包成员完整**：在 **VPC → 共享带宽包** 打开 `shared_bandwidth_package_id` 对应的带宽包，确认成员地址数量等于 1 个 NAT EIP + 每个可用区 1 个 ALB EIP 的总和（默认即 3 个），且与 `nat_eip_address`、`alb_eip_addresses` 一致。如数量不足，优先检查 `alb_eip_bandwidth_mbps`、`shared_bandwidth_package_mbps` 配置以及共享带宽包配额。
2. **公网入向可达 ALB**：在 prd ECS 上启动一个 80 端口的测试服务，然后分别访问 `alb_eip_addresses` 中的每个公网 IP（对应各可用区）；应能稳定收到后端返回。如访问失败，可在 ALB 控制台确认后端服务器组健康检查状态，再核对 prd 安全组是否放通了 dmz 业务子网回源。
3. **dev 统一出向**：登录任一 dev ECS，执行 `curl ifconfig.me` 等任意公网查询服务，返回的公网 IP 应为 `nat_eip_address`。若返回其他 IP 或请求超时，优先检查 dev VPC 路由表是否有 `0.0.0.0/0 → TR`、TR 路由表是否有 `0.0.0.0/0 → dmz Attachment`、NAT 的 SNAT 源网段是否包含 dev VPC CIDR。
4. **prd 默认不出向**：登录任一 prd ECS 执行同样命令，默认情况下应**无法**访问外网。若意外能够出网，请核对 `vpcs.prd.outbound` 是否被改成 `true`，以及 NAT 的 `snat_source_cidrs` 是否误配置了 prd 网段。
5. **路由完整性**：对照 `transit_router_route_table_id` 与 `vpc_route_table_ids`，在控制台核对 TR 自定义路由表包含三个 VPC 的 propagation 条目和 `0.0.0.0/0 → dmz Attachment` 静态路由，dmz / dev / prd 三张 VPC 路由表的下一跳符合预期，并且不存在绕过 dmz 的公网默认路由。

> 以上验证可由客户在部署账号内重复执行。若需要在 prd 侧使用自己的真实业务镜像与端口完成端到端功能性验证，请根据业务规范自行准备测试内容，本模板不负责生成业务流量。

#### 4.2.5 销毁资源

```bash
terraform plan -destroy
terraform destroy
```

注意事项：

- 销毁前确认已取得清理授权，并审核待删除资源；销毁会删除 Terraform 管理的全部云资源，生产环境请确认无误后执行。
- 请先把 ALB 入向流量切走，再执行销毁，避免影响线上业务。
- 创建侧已在代码中按 `dmz → dev → prd` 串行化；销毁侧由 `time_sleep` 等待屏障把 TR Attachment、TR 路由表、NAT、安全组、子网等共享状态机的删除顺序错开，一般无需追加 `-parallelism=1`；若偶发 `InvalidTransitRouter.InvalidStatus` 或 `InvalidEni.InvalidStatus`，可追加后重试：

  ```bash
  terraform destroy -auto-approve -parallelism=1
  ```

- **`InvalidVpc.InUse` 处理**：火山云每个 VPC 会自动创建 1 个默认安全组 + 1 个默认路由表，通常随 VPC 销毁自动回收，不需要也不应手动删除。若 destroy 报 `InvalidVpc.InUse: ... dependent resource of a security group / route table`，一般说明 VPC 中仍残留未纳管的**自定义（非默认）**安全组、路由表或其关联 ENI。处理方式：
  1. 用 `data "volcenginecc_vpc_vpc"` 查询 `security_group_ids` / `route_table_ids`，区分默认与自定义资源。
  2. 在控制台删除残留的**自定义（非默认）**安全组与路由表；删除安全组前确认其关联 ENI 已释放。
  3. 若希望用 Terraform 回收残留的自定义资源，可在临时工程中 `terraform import` 后再 `terraform destroy`；不要 import 默认系统资源。
  4. 重新执行 `terraform destroy`，默认安全组与路由表会随 VPC 一并回收。

## 5. 总结

- **标准化交付**：通过 Terraform 统一创建网络、路由、公网出向、公网入向、带宽聚合与工作负载资源，一键完成集中式公网出入口环境的交付，云资源全部由 `volcenginecc` Provider 管理。
- **集中治理**：跨 VPC 路由集中在 TR 自定义路由表（association + propagation + 静态默认路由，声明式全托管），安全组规则集中在根模块编排，NAT EIP 与各可用区 ALB EIP 集中纳入共享带宽包，符合 Landing Zone 的集中式治理原则。
- **稳定创建与可预期销毁**：TR 相关资源严格串行创建；销毁阶段通过仅销毁生效的 `time_sleep` 等待屏障错开 TR、NAT、子网、安全组的删除顺序，减少 `InvalidStatus`、`InvalidEni.InvalidStatus` 等瞬态错误。
- **多 AZ 高可用**：业务子网与 TR 子网默认跨 AZ 分布，ALB 跨 AZ 部署，ECS 跨子网创建，原生支持高可用场景。
- **模块化复用**：按 `tr-vpc`（网络底座）/ `nat`（出向）/ `alb`（入向）/ `ecs`（工作负载）拆分模块，便于按需组合与独立升级。

可继续演进的方向：

- 接入 `volcenginecc_apig_gateway` 替换 ALB，提供更完整的网关能力（认证、限流、灰度）。
- 集成 `volcenginecc_waf_domain` 做入向 WAF 防护，统一在 dmz VPC 落地。
- 接入 `volcenginecc_iam_role` + 最小权限策略，让 Terraform 执行账号仅持有必要权限。
- 启用 `volcenginecc_vpc_flow_log` 做 TR / VPC 流量审计，与 CLS / Prometheus 联动。
- 接入远端 Backend 管理 Terraform State，支持团队协作与 CI/CD 流水线。
