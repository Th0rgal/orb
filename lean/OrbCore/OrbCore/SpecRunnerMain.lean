import OrbCore.ConformanceRunner

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--fixtures", dir] => OrbCore.ConformanceRunner.runSharedFixtures dir
  | [casesPath] => OrbCore.ConformanceRunner.runCasesFile casesPath
  | _ =>
    IO.eprintln "usage: orb-spec-runner <cases.txt> | --fixtures <fixtures_dir>"
    return 1
