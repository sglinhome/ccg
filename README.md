# CCG (Claude · Codex · Gemini)

通用多模型协作技能包（Universal 4-Phase Multi-Model Skill），基于 **Magpie Gateway**（或任意 OpenAI 兼容网关）调度多路模型，让**任意 Agent**（Pi / Oh-My-Pi / Claude Code / Codex / OpenCode / Antigravity / Cursor）拥有统一的工程协作纪律：

1. **Phase 1 — 需求对齐**：先读代码现状，模糊点必须反问确认，禁止盲猜。
2. **Phase 2 — 多模型互博定方案（Debate & Plan Gate）**：
   - **架构师（`group/plan-review`）** 做失败预演（Pre-Mortem），排查架构、并发、安全与边界漏洞；
   - **工程师（`group/code-pro`）** 给最简落地步骤并反制过度设计；
   - 双方交叉挑刺后收敛为唯一方案，**必须等用户确认后才允许修改代码**。
3. **Phase 3 — 常规模型小步编码**：按确认方案小步落地并跑验证（支持 `consult` 随时问顾问）。
4. **Phase 4 — 高级模型 Diff 严审（Review）**：自动抓取 `git diff` 与**未追踪新建文件**送审，按 `[Blocker]` / `[Concern]` / `[Nit]` 分级把关。

---

## 一键安装（零第三方依赖）

### macOS / Linux
```bash
curl -fsSL https://raw.githubusercontent.com/sglinhome/ccg/main/install.sh | bash
```

### Windows (PowerShell)
```powershell
irm https://raw.githubusercontent.com/sglinhome/ccg/main/install.ps1 | iex
```

---

## 配置网关密钥（与源码隔离）

安装后在本地创建 `~/.ccg.json`（Windows 为 `%USERPROFILE%\.ccg.json`）：

```json
{
  "baseUrl": "http://10.89.10.199:3425/v1",
  "apiKey": "YOUR_GATEWAY_KEY",
  "planModel": "group/plan-review",
  "codeModel": "group/code-pro",
  "timeoutSec": 120
}
```

macOS / Linux 建议收紧权限：
```bash
chmod 600 ~/.ccg.json
```

---

## 使用方式

* **在任意 Agent 中**：直接说 **`ccg 帮我设计并实现……`** 或 **`ccg review`**。
* **独立命令行调用**：
  ```bash
  # 双模型 2 轮互博
  python3 ~/.agents/skills/ccg/scripts/ccg.py debate -p "你的需求描述" -f 相关文件.py

  # 高级模型审核 Git 改动（含新建未追踪文件）
  python3 ~/.agents/skills/ccg/scripts/ccg.py review -r .

  # 向高级顾问提问
  python3 ~/.agents/skills/ccg/scripts/ccg.py consult -p "你的技术问题"
  ```
