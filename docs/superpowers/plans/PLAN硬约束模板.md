# Superpowers PLAN 硬约束模板

> 用途：用于在 `docs/superpowers/plans/` 下编写实施计划，作为 `spec` 和执行步骤之间的控制层。

## 使用原则

1. `plan` 只写实施，不重写需求。
2. `plan` 必须先锁定边界，再拆任务。
3. `plan` 必须明确允许修改什么、禁止修改什么。
4. `plan` 必须明确验证顺序和停止条件。
5. 任何会把工作范围扩大的变化，都必须先停下来重回 `spec`。

## 模板正文

```md
# [主题名称] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一句话说明这次计划要完成什么，且必须与 SPEC 的目标 / 需求快照一致。

**Architecture:** 2-3 句话说明实施思路，不重复 SPEC，不写散文。

**Tech Stack:** 列出执行这次计划必须知道的语言、框架、工具、命令或测试入口。

---

## 1. 计划边界

### 1.1 这次计划要做什么

### 1.2 这次计划明确不做什么

### 1.3 允许修改的文件 / 目录

### 1.4 明确禁止修改的文件 / 目录

### 1.5 如果越界怎么办

写清楚：

- 什么情况下必须停
- 什么情况下必须回到 `spec`
- 什么情况下必须重新确认

## 2. 任务拆解

### Task N: [名称]

**Files:**
- Modify: `exact/path/to/file`
- Test: `exact/path/to/test`

- [ ] **Step 1: 写出最小修改或最小验证**
- [ ] **Step 2: 运行对应验证**
- [ ] **Step 3: 确认结果符合预期**

## 3. 实施顺序

1. 先做什么
2. 再做什么
3. 什么时候暂停检查边界

## 4. 验证顺序

1. 先跑什么验证
2. 再跑什么验证
3. 哪一步通过后才算可以继续

## 5. 停止条件

- 哪些发现会让计划失效
- 哪些发现会让实现暂停
- 哪些变化会要求重新回到 `spec`

## 6. 复核清单

- [ ] 计划没有重复 SPEC 的需求正文
- [ ] 允许修改范围写清楚了
- [ ] 禁止修改范围写清楚了
- [ ] 如果越界，有明确停下和回退规则
- [ ] 任务足够小，不会把多个动作塞进同一步
- [ ] 验证顺序是具体可执行的，不是空话
```
