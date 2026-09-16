"""Exercise bootstrap dispatch without network or NinjaOne dependencies."""
import base64
import json
import pathlib
import subprocess
import tempfile
import unittest

BOOTSTRAP = pathlib.Path(__file__).resolve().parents[1] / 'bootstrap.ps1'


class BootstrapTests(unittest.TestCase):
    def run_bootstrap(self, payload=None, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            runner = pathlib.Path(directory) / 'runner.ps1'
            runner.write_text(r'''
param([string]$Bootstrap, [string]$TempRoot, [string]$Payload, [int]$ChildExit)
$env:TEMP = $TempRoot
function Ninja-Property-Get { return $null }
function Ninja-Property-Set {}
function git { $global:LASTEXITCODE = 1 }
function Invoke-WebRequest { param($Uri, $OutFile, $Headers, [switch]$UseBasicParsing) Set-Content -Path $OutFile -Value '# fixture' }
function powershell.exe {
    $captured = ConvertTo-Json -InputObject @($args) -Compress
    Write-Output "CAPTURE:$captured"
    $global:LASTEXITCODE = $ChildExit
}
$params = @{ ScriptName = 'lab/fixture'; RepoUrl = 'https://github.com/Relianco/device-scripts'; Branch = 'test-ref' }
if ($Payload) { $params.userDataJson = $Payload }
& $Bootstrap @params
if (-not $? -and -not $global:LASTEXITCODE) { exit 1 }
exit $global:LASTEXITCODE
''')
            return subprocess.run(['pwsh', '-NoProfile', '-File', str(runner),
                                   str(BOOTSTRAP), directory, payload or '', str(exit_code)],
                                  capture_output=True, text=True)

    def test_forwards_encoded_request_unchanged(self):
        payload = base64.b64encode(json.dumps({'upn': 'lab@ad-lab.test', 'displayName': 'Lab "User"'}).encode()).decode()
        result = self.run_bootstrap(payload)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        capture = next(line.split('CAPTURE:', 1)[1] for line in result.stdout.splitlines() if 'CAPTURE:' in line)
        arguments = json.loads(capture)
        self.assertEqual(arguments[-2:], ['-userDataJson', payload])

    def test_existing_collectors_receive_no_payload_argument(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        capture = next(line.split('CAPTURE:', 1)[1] for line in result.stdout.splitlines() if 'CAPTURE:' in line)
        self.assertNotIn('-userDataJson', json.loads(capture))

    def test_child_failure_is_preserved(self):
        result = self.run_bootstrap(exit_code=7)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
