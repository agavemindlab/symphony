# Agavemindlab Lite

`agavemindlab-lite` 是 `agavemindlab` workflow 的短提示词版本。

它复用原来的 clone、setup、teardown、Linear、PR、commit、land 等机制，安装简短的
`phase-*` skills，但不要求 artifact 套固定模板。Artifact 只保留标题、结论、证据、
验收、风险和必要澄清。

项目要使用 lite 版时，把项目目录里的入口改成：

```sh
WORKFLOW.md -> ../agavemindlab-lite/WORKFLOW.md
skills -> ../agavemindlab-lite/skills
```

项目自己的 `project.env`、`setup.sh`、`teardown.sh` 保持不变。
