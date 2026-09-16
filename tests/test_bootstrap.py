"""Run the installed v2 collector flow and parameter mode with local fixture downloads."""
import base64
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

BOOTSTRAP = pathlib.Path(__file__).resolve().parents[1] / 'bootstrap.ps1'


class BootstrapTests(unittest.TestCase):
    def run_bootstrap(self, payload=None, exit_code=0, parameters=None, script_name='lab/fixture'):
        with tempfile.TemporaryDirectory() as directory:
            runner = pathlib.Path(directory) / 'runner.ps1'
            os.symlink(shutil.which('pwsh'), pathlib.Path(directory) / 'powershell.exe')
            runner.write_text(r'''
param([string]$Bootstrap, [string]$TempRoot, [string]$Payload, [int]$ChildExit, [string]$Parameters, [string]$Target)
$env:TEMP = $TempRoot
$env:ProgramData = $TempRoot
$env:PATH = $TempRoot + [IO.Path]::PathSeparator + $env:PATH
function Ninja-Property-Get { return $null }
function Ninja-Property-Set {}
function Invoke-WebRequest {
    param($Uri, $OutFile, $Headers, [switch]$UseBasicParsing)
    if ($Uri.EndsWith('checksums.sha256')) { throw 'Fixture has no manifest' }
    if ($Uri.EndsWith('profiles.json')) { Set-Content $OutFile '{}'; return }
    $fixture = 'param([string]$Name, [bool]$Enabled, [string[]]$Groups, [string]$userDataJson) ConvertTo-Json -Compress @{Name=$Name;Enabled=$Enabled;Groups=$Groups;userDataJson=$userDataJson}'
    $fixture += '; exit ' + $ChildExit
    Set-Content -Path $OutFile -Value $fixture
}
$params = @{ ScriptName = $Target; RepoUrl = 'https://github.com/Relianco/device-scripts'; Branch = 'test-ref' }
if ($Payload) { $params.userDataJson = $Payload }
if ($Parameters) { $params.ParametersBase64 = $Parameters }
& $Bootstrap @params
if (-not $? -and -not $global:LASTEXITCODE) { exit 1 }
exit $global:LASTEXITCODE
''')
            return subprocess.run(['pwsh', '-NoProfile', '-File', str(runner), str(BOOTSTRAP),
                                   directory, payload or '', str(exit_code), parameters or '', script_name],
                                  capture_output=True, text=True, timeout=30)

    def output(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(next(line for line in result.stdout.splitlines() if line.startswith('{')))

    def test_forwards_encoded_request_unchanged(self):
        payload = base64.b64encode(json.dumps({'upn': 'lab@ad-lab.test'}).encode()).decode()
        self.assertEqual(self.output(self.run_bootstrap(payload))['userDataJson'], payload)

    def test_existing_collector_flow_still_runs_without_parameters(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('collectors completed successfully', result.stdout)

    def test_generic_parameters_preserve_types_and_literal_text(self):
        parameters = {'Name': 'Lab "user"; $(throw "not code")', 'Enabled': False, 'Groups': ['One', 'Two words']}
        encoded = base64.b64encode(json.dumps(parameters).encode()).decode()
        output = self.output(self.run_bootstrap(parameters=encoded))
        self.assertEqual({key: output[key] for key in parameters}, parameters)

    def test_generic_parameters_reject_non_object(self):
        result = self.run_bootstrap(parameters=base64.b64encode(b'[]').decode())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be a JSON object', result.stdout + result.stderr)

    def test_child_failure_is_preserved(self):
        result = self.run_bootstrap(exit_code=7, parameters='e30=')
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)

    def test_collector_nonzero_exit_is_failure_even_with_json_output(self):
        result = self.run_bootstrap(exit_code=7)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_single_script_mode_rejects_traversal(self):
        result = self.run_bootstrap(parameters='e30=', script_name='../fixture')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid script path', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
