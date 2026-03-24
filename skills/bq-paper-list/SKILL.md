---
name: bq-paper-list
description: "Daily paper discovery skill. Builds a fixed daily shortlist for agent-related papers, prioritizing agent, code generation, bug fixing, system configuration optimization, synthetic data, and RAG indexing. Use when the user wants today's papers, a daily Top 5, or a filtered paper list before deep reading."
user_invocable: true
version: "1.0.0"
---

# bq-paper-list: 每日筛论文

目标不是把论文池铺满，而是每天给出一份能直接开读的 Top 5。

默认看今天，默认输出 5 篇，默认面向以下兴趣排序：

1. agent、自动代码生成、Bug 修复、系统配置优化
2. LLM agent infrastructure、tool use、planning、workflow orchestration、code reasoning
3. 高质量合成数据生成
4. RAG 索引优化
5. 其他当天非常热门且对通用智能体/LLM 系统有外溢价值的论文

## 使用场景

用户有以下意图时使用：

- 想看“今天值得读的论文”
- 想在深读前先做论文筛选
- 想聚焦 agent / code / RAG / synthetic data 方向
- 想每天固定获取一份高信号论文清单

## 输入与默认值

- 默认日期：今天
- 默认数量：5 篇主推荐 + 1-3 篇补充推荐
- 默认来源：`arXiv + Hugging Face Papers`
- 若用户显式指定日期，则覆盖默认日期

日期在输出中必须写绝对日期，不要只写“今天”。

## 执行步骤

### 1. 确定日期范围

- 默认使用今天的绝对日期
- 若数据源按 UTC 更新，而用户未指定时区，按用户当前环境时区解释输出日期
- 若当天论文明显过少，可说明“当天供给不足”，但不要静默放宽到更早日期

### 2. 收集候选池

先读 [references/source-policy.md](references/source-policy.md)。

- 从 `arXiv` 获取当天新增论文，作为主候选池
- 从 `Hugging Face Papers` 获取当天或当前页热点论文，作为热度信号
- 若后续用户要求扩展，可再接入 `OpenReview` 或 `OpenAlex`

收集时至少保留以下字段：

- 标题
- 链接
- 摘要
- 作者
- 日期
- 来源
- 分类或标签

### 3. 去重与标准化

- 以 arXiv id、DOI、主链接为优先键去重
- 标题轻微差异时，按语义近似合并同一论文
- 合并后保留最完整的一份元数据，并记下其命中的所有来源

### 4. 硬过滤

先读 [references/scoring-rubric.md](references/scoring-rubric.md)。

直接剔除：

- 纯理论数学证明，且看不出系统、方法、工程、开源潜力的论文
- 非计算机科学领域的跨学科应用论文
- 只有应用包装，没有方法增量的工作
- 与用户关注方向弱相关，且也不具备明显通用价值的论文

允许保留的例外：

- 跨学科论文，但核心贡献是通用架构、训练机制、推理机制、索引机制或系统优化
- 非直接命中兴趣方向，但当天非常热门且可能对智能体/LLM 系统产生明显外溢价值

### 5. 打分排序

按 [references/scoring-rubric.md](references/scoring-rubric.md) 执行：

- 先做主题相关性打分
- 再评估工程落地与开源潜力
- 再用 `Hugging Face Papers` 做热度修正
- 热度不能压过主题相关性

如果两篇论文分数接近，优先：

- 更接近 agent / code / system optimization 主线
- 更有复现或开源实现潜力
- 更少纯 benchmark 或纯数据堆料味道

### 6. 多样性控制

- Top 5 中同类方向最多 2 篇
- 不要让 5 篇都落在同一子方向
- 如果当天主线方向过于集中，补充推荐位可以留给高热但不同类的论文

### 7. 生成日报

按 [references/output-template.md](references/output-template.md) 的结构输出。

必须包含：

- 绝对日期
- 数据源概览
- 候选池规模与过滤结果
- Top 5 推荐
- 1-3 篇补充推荐
- 未入选类型摘要

每篇 Top 5 论文都要回答：

- 它解决了什么问题
- 为什么和用户关注点强相关
- 是否有工程落地或开源潜力
- 是否建议交给 `bq-paper` 深读

## 输出风格

- 直接给结论，不写成搜索日志
- 推荐理由要短，但要有判断
- 不要只复述摘要，要明确说“为什么值得读”
- 对明显可能是包装式工作，要点出风险
- 若当天没有足够高质量候选，允许少于 5 篇，但必须明确说明原因

## 与 bq-paper 的衔接

`bq-paper-list` 只负责发现与筛选，不负责深读。

推荐衔接方式：

1. 先用 `bq-paper-list` 生成当日 Top 5
2. 从 Top 5 中选择 1-5 篇标记为“建议交给 `bq-paper` 深读”的论文
3. 再逐篇调用 `bq-paper` 做深入理解与 Markdown 笔记输出

如果用户明确表达“筛完后继续深读”，可以这样组织回应：

- 先给出日报
- 再单独列出“建议下一步交给 `bq-paper` 的 1-3 篇”
- 不要在同一次输出里把日报和深读长文混在一起

先筛，再读。不要把两个 skill 的职责揉成一个长输出。

## 示例

日报格式参考 [references/output-template.md](references/output-template.md)。

如果需要示例口径，可参考 [references/example-report.md](references/example-report.md)。

## 质量标准

- _够窄_：不是泛泛 AI 论文列表，而是围绕用户关注方向的高信号清单
- _够稳_：每天都按同一口径出结果，便于长期积累
- _够准_：热点只能修正排序，不能取代主题相关性
- _够用_：用户看完就知道先读哪几篇，哪些不用浪费时间
