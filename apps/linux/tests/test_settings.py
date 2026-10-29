import json
import stat

from swell.settings import DEFAULT_MODEL, Settings, load_settings, save_setting, server_token, vocab


def test_reads_settings_written_by_whisper_dictate(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"load_model": "large-v3-turbo", "startup_model": "large-v3-turbo", "cleanup": True, "serve": True, "device": "cuda"}))
    assert load_settings(path) == Settings(load_model="large-v3-turbo", startup_model="large-v3-turbo", device="cuda", cleanup="medium", serve=True)


def test_cleanup_switch_becomes_a_level(tmp_path):
    path = tmp_path / "settings.json"
    for stored, level in ((True, "medium"), (False, "off"), ("high", "high"), ("max", "off")):
        path.write_text(json.dumps({"cleanup": stored}))
        assert load_settings(path).cleanup == level


def test_unknown_or_missing_values_fall_back_to_defaults(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"load_model": "huge", "device": "tpu", "cleanup": "yes"}))
    assert load_settings(path) == Settings(load_model=DEFAULT_MODEL, cleanup="off")
    assert load_settings(tmp_path / "missing.json") == Settings()


def test_save_setting_keeps_other_settings(tmp_path):
    path = tmp_path / "config" / "settings.json"
    save_setting("serve", True, path)
    assert save_setting("device", "cpu", path) == Settings(device="cpu", serve=True)
    assert load_settings(path) == Settings(device="cpu", serve=True)


def test_server_token_is_private_and_stable(tmp_path):
    path = tmp_path / "server_token"
    token = server_token(path)
    assert len(token) >= 32
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert server_token(path) == token


def test_vocab_joins_terms(tmp_path):
    path = tmp_path / "vocab.txt"
    path.write_text("Needl\nKubernetes\n")
    assert vocab(path) == "Needl, Kubernetes"
    assert vocab(tmp_path / "missing.txt") is None
