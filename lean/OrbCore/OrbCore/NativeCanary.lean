namespace OrbCore.NativeCanary

/-- An optional operator rollout fence, independent of account ownership and user preferences.
    A present but incomplete setting never enables native profile execution. -/
inductive Scope where
  | unrestricted
  | selected (node owner account : String)
  | invalid (node : String)
  deriving BEq, Repr

def parse (binding : Option String) (workspace : String) : Scope :=
  match binding with
  | none => .unrestricted
  | some raw =>
    match raw.splitOn "/" with
    | [owner, account] =>
      if !workspace.isEmpty && !owner.isEmpty && !account.isEmpty then .selected workspace owner account
      else .invalid workspace
    | _ => .invalid workspace

def load : IO Scope := do
  return parse (← IO.getEnv "ORB_NATIVE_SUBSCRIPTION_CANARY")
    ((← IO.getEnv "ORB_NATIVE_WORKSPACE_NODE").getD "")

def Scope.reserves (scope : Scope) (node : String) : Bool :=
  match scope with
  | .unrestricted => false
  | .selected target .. | .invalid target => !target.isEmpty && target == node

def Scope.permitsNode (scope : Scope) (node owner : String) : Bool :=
  match scope with
  | .selected target member _ => node != target || owner == member
  | .invalid _ => !scope.reserves node
  | .unrestricted => true

/-- The account restriction is applied before probing a subscription. -/
def Scope.accountFor (scope : Scope) (node owner : String) : Except Unit (Option String) :=
  match scope with
  | .unrestricted => .ok none
  | .selected target member account =>
    if node == target && owner == member then .ok (some account) else .error ()
  | .invalid _ => .error ()

end OrbCore.NativeCanary
