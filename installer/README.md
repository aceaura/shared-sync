# 打包与发布

本目录是桌面客户端的安装器打包脚本;发布由 GitHub Actions 自动完成。

## 自动发布(推荐)

1. 在工程根目录执行触发脚本:

   ```bash
   scripts/release.sh 1.0.1
   ```

   它会更新桌面应用版本号、提交、打 `v1.0.1` tag 并推送。

2. 推送 tag 触发 [.github/workflows/release.yml](../.github/workflows/release.yml),三个并行任务:
   - **macOS**:`flutter build macos` → `installer/macos/make-dmg.sh` 打成可拖拽的 `.dmg`;
   - **Windows**:`flutter build windows` → Inno Setup([installer/windows/installer.iss](windows/installer.iss))打成 `.exe` 安装器;
   - **服务端镜像**:构建 `server/` 镜像推送到 `ghcr.io/aceaura/shared-sync-server`(打 `<版本>` 与 `latest` 两个 tag)。
   - 两个桌面安装包作为附件发布到对应 GitHub Release。

3. 也可在 GitHub 网页 Actions 里手动触发(workflow_dispatch),填入 tag —— 主要用于重建桌面安装器。

## 本地手动打包

- macOS:

  ```bash
  cd client/app && flutter build macos --release
  bash installer/macos/make-dmg.sh      # 产出 client/app/build/macos/shared-sync-macos-<版本>.dmg
  ```

- Windows(需在 Windows 上,装 Inno Setup 6):

  ```powershell
  cd client/app; flutter build windows --release
  & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DMyAppVersion=1.0.1 installer\windows\installer.iss
  # 产出 installer\windows\Output\shared-sync-windows-<版本>-setup.exe
  ```

## 关于代码签名

当前安装包**未签名**(无 Apple Developer ID / Windows 代码签名证书)。首次打开:

- **macOS**:Gatekeeper 会拦截。右键应用图标 → 打开 → 确认;或在「系统设置 → 隐私与安全性」点「仍要打开」。
- **Windows**:SmartScreen 提示「Windows 已保护你的电脑」→ 点「更多信息」→「仍要运行」。

若日后有证书,在 [release.yml](../.github/workflows/release.yml) 的 macOS/Windows 任务里加签名步骤(证书走 GitHub Secrets),即可产出免警告安装包。
