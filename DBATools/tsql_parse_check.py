"""Static syntax check of T-SQL files with Microsoft ScriptDom (TSql170, Azure engine type).

It proves the script parses. It does not bind object or column names: only a run on Azure SQL
Database proves those.

Run:  uv run --no-project --with pythonnet==3.0.5 python tsql_parse_check.py <file.sql> [...]
Needs: the VS Code mssql extension (ScriptDom dll) and the VS Code .NET runtime (both found by glob).
Exit code 0 = no parse errors, 1 = parse errors, 2 = parser or runtime not found.
"""
import glob
import os
import shutil
import sys
import tempfile

HOME = os.path.expanduser("~")
runtimes = sorted(
    (d for d in glob.glob(os.path.join(
        HOME, "Library/Application Support/Code/User/globalStorage/ms-dotnettools.vscode-dotnet-runtime/.dotnet/*"))
     if os.path.isdir(os.path.join(d, "host", "fxr"))),  # some folders hold no runtime
    key=os.path.getmtime)
dlls = sorted(glob.glob(os.path.join(
    HOME, ".vscode/extensions/ms-mssql.mssql-*/BuildDirectory/Microsoft.SqlServer.TransactSql.ScriptDom.dll")))
if not runtimes or not dlls:
    print("ScriptDom dll or .NET runtime not found")
    sys.exit(2)

work = tempfile.mkdtemp(prefix="scriptdom-")
dll = shutil.copy(dlls[-1], work)  # loading it from inside the extension folder fails
cfg = os.path.join(work, "rt.json")
with open(cfg, "w") as f:
    f.write('{"runtimeOptions":{"tfm":"net10.0","framework":{"name":"Microsoft.NETCore.App","version":"10.0.0"},"rollForward":"LatestMajor"}}')

from clr_loader import get_coreclr  # noqa: E402
from pythonnet import set_runtime  # noqa: E402

set_runtime(get_coreclr(runtime_config=cfg, dotnet_root=runtimes[-1]))
import clr  # noqa: E402,F401  (registers the .NET import hook)
import System.Reflection  # noqa: E402

System.Reflection.Assembly.LoadFrom(dll)
from Microsoft.SqlServer.TransactSql import ScriptDom  # noqa: E402
from System.IO import StringReader  # noqa: E402

failed = False
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    result = ScriptDom.TSql170Parser(True, ScriptDom.SqlEngineType.SqlAzure).Parse(StringReader(text), None)
    errors = result[1]
    print(f"{os.path.basename(path)}: {errors.Count} parse error(s)")
    for i in range(min(errors.Count, 20)):
        print(f"  line {errors[i].Line} col {errors[i].Column}: {errors[i].Message}")
    failed = failed or errors.Count > 0
sys.exit(1 if failed else 0)
