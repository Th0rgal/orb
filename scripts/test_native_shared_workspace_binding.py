"""Replay the Core-held profile eligibility query on a shared account and two members."""
import sqlite3
from pathlib import Path

QUERY = (Path(__file__).resolve().parents[1] / "lean/OrbCore/OrbCore/native_shared_workspace.sql").read_text()

def run():
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE native_antigravity_grants(token_sha256,job_id,account_id,model);
        CREATE TABLE native_shared_workspace_bindings(token_sha256,node_id,route_generation);
        CREATE TABLE mission_proxy_tokens(token_sha256,mission_id,owner_user_id,expires_at_epoch,revoked);
        CREATE TABLE remote_node_jobs(job_id,node_id,mission_id,state);
        CREATE TABLE missions(id,owner_user_id,status,placement_job_id,backend,authority_mode,run_generation,owner_epoch,placement_revision);
        CREATE TABLE users(id,unix_username,role,disabled);
        CREATE TABLE account_vpn_routes(account_id,country,generation);
        CREATE TABLE user_provider_prefs(user_id,provider_id,enabled);
        INSERT INTO native_antigravity_grants VALUES ('digest','job','shared','carbon');
        INSERT INTO native_shared_workspace_bindings VALUES ('digest','worker',9);
        INSERT INTO mission_proxy_tokens VALUES ('digest','mission','ben',900,0);
        INSERT INTO remote_node_jobs VALUES ('job','worker','mission','running');
        INSERT INTO missions VALUES ('mission','ben','active','job','antigravity','writer',1,1,8);
        INSERT INTO users VALUES ('ben','orb-ben','member',0), ('other','orb-other','member',0);
        INSERT INTO account_vpn_routes VALUES ('shared','NL',9);
        INSERT INTO user_provider_prefs VALUES ('other','shared',0);
    """)
    args = ["digest", "job", "worker", "ben", "600"]
    def matches():
        return db.execute(QUERY, args).fetchall()
    assert matches() == [('mission','ben','orb-ben','job','worker','shared','carbon','writer',1,1,8,'NL',9,900)]
    for query in (
        "INSERT INTO user_provider_prefs VALUES ('ben','shared',0)",
        "UPDATE users SET disabled=1 WHERE id='ben'",
        "UPDATE users SET unix_username=NULL WHERE id='ben'",
        "UPDATE missions SET owner_user_id='other'",
        "UPDATE missions SET placement_job_id='next'",
        "UPDATE missions SET status='interrupted'",
        "UPDATE missions SET backend='codex'",
        "UPDATE remote_node_jobs SET state='cancelled'",
        "UPDATE remote_node_jobs SET node_id='next'",
        "UPDATE native_shared_workspace_bindings SET node_id='next'",
        "UPDATE native_shared_workspace_bindings SET route_generation=8",
        "UPDATE account_vpn_routes SET generation=10",
        "UPDATE account_vpn_routes SET country=''",
        "UPDATE native_antigravity_grants SET account_id='other-account'",
        "DELETE FROM native_shared_workspace_bindings",
        "UPDATE mission_proxy_tokens SET revoked=1",
        "UPDATE mission_proxy_tokens SET expires_at_epoch=600",
    ):
        db.execute("SAVEPOINT replay")
        db.execute(query)
        assert not matches(), query
        db.execute("ROLLBACK TO replay")
        db.execute("RELEASE replay")
    for index in range(4):
        original, args[index] = args[index], "different"
        assert not matches()
        args[index] = original
    print("Shared account accepted for eligible member; 21 authority mismatches rejected.")


if __name__ == "__main__":
    run()
