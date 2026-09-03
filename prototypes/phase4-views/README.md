# Phase 4 multi-view prototype

独立、只读数据源的交互原型。所有任务、附件预览与写操作都在浏览器内存中模拟；页面 CSP 禁止网络连接。

## Run

```powershell
& "C:\Users\wangz\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe" server.cjs
```

然后打开 `http://127.0.0.1:4174`。

## Keyboard

- `/`：聚焦搜索
- `←` / `→`：切换视图标签；在 Cover Flow 中切换任务
- `Home` / `End`：第一/最后一个视图或封面
- `Space`：选择聚焦任务
- `Enter`：打开聚焦任务详情
- `Esc`：关闭详情

右上角设置可切换简洁/专业字段、Reduce Motion 和 10,000 条压力数据。

## Contents

- `model.js`：模拟 v3 任务与共享查询规则
- `app.js`：六视图、共享选择、交互与 Three.js 生命周期
- `covers.js`：本地 Canvas 模拟提交封面
- `vendor/`：固定版本 Three.js 0.180.0 与 Lucide 图标，含原许可证
- `screenshots/`：经 Chromium 验证的交付截图
