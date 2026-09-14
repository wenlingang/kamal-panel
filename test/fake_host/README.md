# 测试夹具密钥

本目录中的 `id_ed25519` 是**故意提交进仓库的测试密钥**，仅用于本地与 CI 中的
fake host 容器。它不保护任何真实资产。

请勿将其用于任何真实服务器。

## 为什么 CI 里有一步 `chmod 600 id_ed25519`

Git 只记录可执行位，不记录读写权限位。这个私钥在本地是用
`ssh-keygen` 生成的，一直是 `600`；但每一次全新 `git clone`/`checkout`
（包括每一次 CI 运行）都会把它落盘成 `644`。OpenSSH **客户端**会拒绝
以 `644` 加载私钥，报 `UNPROTECTED PRIVATE KEY FILE`，然后认证失败。

`bin/rails test` 走的是 Ruby 的 `net-ssh`，它不做这个权限检查，所以本地
跑测试完全看不出问题——只有真正调用系统 `ssh` 客户端（CI 的就绪探测步骤
就是这么做的）才会暴露。

所以 `.github/workflows/ci.yml` 的 `test` job 里必须在任何 `ssh` 调用之前
执行 `chmod 600 test/fake_host/id_ed25519`。**不要删除这一步**，否则 CI 会
在一次全新 checkout 后必现失败。
