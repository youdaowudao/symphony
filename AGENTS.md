## 身份
你的文件操作权限仅限于项目内的所有文件，禁止修改项目外任何文件。


## Linear
- Linear属于生产环境，任何改动，写入，删除等操作都需要非常谨慎认真复核。
- 如果并没有被要求去写入Linear，那么不需要去管Linear。

## 联网规则
- 每次联网前必须调用Web Search Routing技能进行对联网工具的路由选择，禁止跳过。

## 需求分析与 PLAN 阶段

- 本节只定义主入口规则；需求阶段的详细要求、展开说明与补充约束，统一见 `/docs/initiatives/SPEC/需求阶段分析详细要求.md`。
- 需求分析、范围取舍、优先级、非目标、技术路线，以及是否进入实现阶段，必须由人类最终决定。
- 在这一阶段，AI 只负责：查资料、补文档、对比方案、解释技术、提示风险、提出发散方向、整理结论与执行材料。
- AI 可以提建议，但不得把建议、推测或偏好直接写成既定需求、既定优先级、既定边界或既定方案。
- 只要涉及平台、框架、服务或工具，AI 必须先补齐可用文档；优先使用本地资料库 `/home/ss/data/documents/各种开发文档`。如果资料不足，AI 应提醒人类补充下载，并更新对应资料入口或插件。
- 在规划阶段，AI 必须先列出本次涉及的技术范围，并用人类可理解的语言解释；避免术语堆砌、黑话堆砌和含混表达。
- AI 写规划和功能说明时，必须准确、正面、具体描述每项功能的目的、边界、输入输出、约束和非目标；不得用一句空泛描述代替。
- 当目标、边界、优先级或取舍标准尚未明确时，AI 不得自行收敛、默认拍板或默认进入实现；应先提问、列选项并等待人类确认。
- PLAN 阶段由人类与 AI 共同完成；未经人类明确确认，AI 不得默认进入实现阶段。

## 测试与校验

  完整测试制度统一见 `elixir/TESTING.md`。

- `WORKFLOW.md` 和 `AGENTS.md` 不再各自展开完整测试制度，只保留运行期必须看到的短入口。
- PR create/update 前，按 `elixir/TESTING.md` 选择并通过当前 `Next Push Gate`。
- 开发阶段默认只用 targeted tests；`make all` 不是默认开发命令，也不是复现工具。
- 所有测试命令都必须显式带上 `SYMPHONY_TEST_MAX_CASES`；默认 `4`。
- 凡是涉及 `Port.open`、`ssh`、`codex app-server`、Docker 或 fake workers 的测试，都必须显式启动并显式 cleanup。
  
  
## 变更流程

  完整变更推进、PR 收口、review 与文档同步规则流程统一见 `elixir/CHANGE_FLOW.md`。

- 禁止直接在主线上操作，禁止直接向远端推送主线；默认先在开发分支上工作。
- git提交信息，PR信息等要求全部采用简体中文，专有名词、命令、协议名、状态名、工具名可以保留英文。
- PR create/update 前，先按 `elixir/CHANGE_FLOW.md` 判断当前阶段，再按 `elixir/TESTING.md` 完成当前 `Next Push Gate`。
- 代码新增、删除、重构或行为变更，PR create/update 前必须完成 1 次独立 `final zero-context reviewer`。
- PR create/update、review reply、PR/issue comment 审计和 merge，默认唯一允许路径是 `../.codex/skills/github_api.py`。
- 每次成功创建 PR 或成功 push branch-update 之后，第一优先级 GitHub 动作必须是立即尝试开启 auto-merge。
- 行为、配置、测试制度、变更流程或 workflow/config contract 发生变化时，必须在同一个 PR 中同步更新对应文档。

## 文档阶段执行与review规则

  完整文档阶段规则统一见 `elixir/PLANNING_FLOW.md`。

- 人类主导的需求讨论要求，见 `/docs/initiatives/SPEC/需求阶段分析详细要求.md`。
- AI 自己分析和 AI 自己写开发文档时，先按 `elixir/PLANNING_FLOW.md` 判定 `discussion level`，再决定是否需要子代理 review。
- 会直接作为后续实现依据的 plan、spec、implementation plan，在进入实现前必须先通过 `elixir/PLANNING_FLOW.md` 规定的文档阶段 review。
  
## 文档与目标文件约束
- 如果未能定位到用户指定的现有文件、目录或原始上下文，必须立即停止，并明确说明未找到。
- 本仓库文档归档以根目录 `SPEC.md` 和 `docs/` 为准；`SPEC.md` 只承载项目级总规范，`docs/` 承载人类文档归档。
- `docs/governance/` 是可复用规则层；本仓库特有的执行要求、验证要求和文档落点摘要统一写在 `AGENTS.md`；根目录 `SPEC.md` 仅用于描述本仓库系统规格，不作为通用治理模板。
- 新增 repo 文档前，先阅读 `docs/README.md` 与 `docs/governance/文档分类规则.md`，按文档类型选择落点，不得按工具名新建长期目录。
- 目录名统一使用英文；文档标题,文档名尽量使用简体中文；专有名词、命令、协议名、状态名、工具名可以保留英文。
- `Superpowers` 是方法，不是归档轴；设计、计划、验证文档默认落到 `docs/changes/<change-id>/`，事故复盘落到 `docs/incidents/`，长期愿景、路线图、未完成功能与技术路线裁决落到 `docs/initiatives/`。
- `docs/changes/<change-id>/` 的文件数量和拆分深度由作者按任务复杂度自行决定；不要为了套模板强行凑固定件数，但必须有清晰入口和不重复职责。
- `docs/changes/<change-id>/` 的入口文件必须包含稳定的“目标 / 需求快照”，至少说明要解决什么问题、成功标准、明确不做什么以及当前固定约束；目标快照用于让 reviewer 尽量不依赖 Linear 也能审查实现是否命中需求。
- 小修小改默认不新建 repo 文档；满足“小修小改”条件且可由 diff + 定向测试直接证明的任务，只在 Linear issue body / `## Codex Workpad` 保留最小执行记录。
- 下列目录视为历史归档，不再作为新文档默认落点：`docs/superpowers/`、`docs/plan_rerun_fix/`、`docs/symphony_ext_plan/`。只有在用户明确要求修改原文件或执行迁移时，才允许继续写入这些目录。
- 单次高风险变更文档放 `docs/changes/`；事故分析放 `docs/incidents/`；长期愿景、路线图、未完成功能清单和技术路线 / A-B 裁决都放 `docs/initiatives/`。
- 不是每个 bug 都升级为 `incident`；只有当问题影响真实流转、跨多个 ticket / PR / session、需要保留时间线与证据链，或根因分析具有长期复用价值时，才建立 `docs/incidents/<incident-id>/`。
- 若某个事故的代码修复本身也复杂或高风险，可同时建立 `docs/changes/<change-id>/`；`incident` 写事实与根因，`change` 写实现与验证，二者不要重复抄写。
