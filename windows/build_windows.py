import subprocess
import os
import shutil

fontUse = '''
  fonts:
    - family: font
      fonts:
        - asset: fonts/NotoSansSC-Regular.ttf
'''

def find_iscc():
    env_path = os.environ.get("ISCC")
    if env_path and os.path.exists(env_path):
        return env_path

    from_path = shutil.which("iscc") or shutil.which("ISCC")
    if from_path:
        return from_path

    program_files_x86 = os.environ.get("ProgramFiles(x86)")
    program_files = os.environ.get("ProgramFiles")
    candidates = [
        os.path.join(program_files_x86, "Inno Setup 6", "ISCC.exe") if program_files_x86 else None,
        os.path.join(program_files, "Inno Setup 6", "ISCC.exe") if program_files else None,
        os.path.join(program_files_x86, "Inno Setup 5", "ISCC.exe") if program_files_x86 else None,
        os.path.join(program_files, "Inno Setup 5", "ISCC.exe") if program_files else None,
    ]
    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            return candidate

    return None

file = open('pubspec.yaml', 'r')
content = file.read()
file.close()
file = open('pubspec.yaml', 'a')
file.write(fontUse)
file.close()

subprocess.run(["flutter", "build", "windows"], shell=True)

file = open('pubspec.yaml', 'w')
file.write(content)

if os.path.exists("build/app-windows.zip"):
    os.remove("build/app-windows.zip")

version = str.split(str.split(content, 'version: ')[1], '+')[0]

# 压缩build/windows/x64/runner/Release, 生成app-windows.zip, 使用tar命令
subprocess.run(["tar", "-a", "-c", "-f", f"build/windows/PicaComic-{version}-windows.zip", "-C", "build/windows/x64/runner/Release", "."]
               , shell=True)

issContent = ""
file = open('windows/build.iss', 'r')
issContent = file.read()
newContent = issContent
newContent = newContent.replace("{{version}}", version)
newContent = newContent.replace("{{root_path}}", os.getcwd())
file.close()
file = open('windows/build.iss', 'w')
file.write(newContent)
file.close()

try:
    iscc = find_iscc()
    if not iscc:
        print("WARN: 未找到 Inno Setup 编译器 (iscc/ISCC.exe)，跳过生成安装包。")
        print("      你仍然会得到 build/windows/... 的 Release 文件夹和 zip。")
        print("      安装 Inno Setup 后重跑本脚本，或设置环境变量 ISCC=ISCC.exe 完整路径。")
    else:
        subprocess.run([iscc, "windows/build.iss"], check=True)
finally:
    with open('windows/build.iss', 'w') as file:
        file.write(issContent)
