import unittest

from muse_runtime.core import derive_session_id
from muse_runtime.server import ollama_done_reason, ollama_to_openai


class HttpHelperTests(unittest.TestCase):
    def test_ollama_image_shape_converts_to_openai_multimodal_shape(self):
        source = [{"role": "user", "content": "describe", "images": ["iVBORw0KGgo="]}]
        result = ollama_to_openai(source)
        self.assertEqual("text", result[0]["content"][0]["type"])
        self.assertTrue(result[0]["content"][1]["image_url"]["url"].startswith("data:image/png;base64,"))

    def test_automatic_session_id_is_stable_but_keyed(self):
        messages = [{"role": "user", "content": "same opening"}]
        first = derive_session_id(b"secret-a", "192.0.2.1", messages)
        second = derive_session_id(b"secret-a", "192.0.2.1", messages)
        other = derive_session_id(b"secret-b", "192.0.2.1", messages)
        self.assertEqual(first, second)
        self.assertNotEqual(first, other)
        self.assertNotIn("same", first)

    def test_length_finish_reason_is_preserved_for_ollama_clients(self):
        self.assertEqual("length", ollama_done_reason("length"))
        self.assertEqual("length", ollama_done_reason("max_tokens"))
        self.assertEqual("stop", ollama_done_reason(None))


if __name__ == "__main__":
    unittest.main()
