# bq-skills

个人维护的 skill 仓库。

## 目录结构

```text
.
├── AGENTS.md
├── README.md
└── skills/
    ├── bq-paper/
    └── bq-paper-list/
```

## 组织约定

- 所有 skill 统一放在 `skills/` 目录下
- 当前不按类型分目录
- 每个 skill 使用独立子目录管理

单个 skill 的推荐结构：

```text
skills/<skill-name>/
├── SKILL.md
├── scripts/      # 可选，skill 专属脚本
├── references/   # 可选，按需加载的参考资料
└── assets/       # 可选，模板或静态资源
```

## 命名建议

- skill 目录名使用短横线风格，例如 `paper-review`
- 一个目录只表示一个 skill
- `SKILL.md` 作为 skill 入口文件
