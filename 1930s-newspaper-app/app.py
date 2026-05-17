import gradio as gr
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
import threading
import sys
import os
import re
import uuid
import datetime
import gc
import shutil

# Add local talkie module to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "talkie", "src"))
try:
    from talkie import Message as TalkieMessage, Talkie
except ImportError:
    print("Talkie module not found. Please ensure it is cloned correctly.")

# ==========================================
# 1. Authentic JCross V7 Spatial Memory
# ==========================================
class AuthenticJCrossMemory:
    """
    Authentic implementation derived from Verantyx Cortex V7.
    Uses pure text-based '.jcross' files with precise cognitive block formatting.
    """
    def __init__(self, base_dir="./verantyx_jcross_v7"):
        self.base_dir = base_dir
        self.zones = ["l1_topology", "front", "near", "mid", "deep"]
        self.boot_system()
        
    def boot_system(self):
        for zone in self.zones:
            os.makedirs(os.path.join(self.base_dir, zone), exist_ok=True)
            
        # Initialize authentic L1/L2 Dictionary nodes if empty
        l1_dir = os.path.join(self.base_dir, "l1_topology")
        if not os.path.exists(os.path.join(l1_dir, "L1_INDEX.jcross")):
            self.write_raw_node("l1_topology", "L1_INDEX", """■ JCROSS_L1_TOPOLOGY
【空間座相】 [Z:-1]
【位相タグ】 [標: 指示] [認: 1.0] [視: 0.8]
【メタデータ】 Initial topology mapping for Verantyx 1930s environment
""")
            
        front_dir = os.path.join(self.base_dir, "front")
        if not os.path.exists(os.path.join(front_dir, "DICT_1930.jcross")):
            self.write_raw_node("front", "DICT_1930", """■ JCROSS_NODE_DICT_1930
【空間座相】 [Z:0]
【次元概念】 #Design #1930 #Newspaper #Aesthetics
【操作軌道】 [引: CORE_PERSONA]
[本質記憶]
//! OP.SET_COLOR("Sepia Paper", "background-color: #f4ecd8; color: #2c241b;")
//! OP.USE_CSS_COLUMNS("Columns", "column-count: 2 or 3; column-gap: 20px; column-rule: 1px solid #3b2f2f;")
//! OP.USE_BORDERS("Dividers", "border-top: 4px double #1a1a1a; border-bottom: 2px solid #1a1a1a;")
//! [HTML/CSS Structural Dictionary] Use strictly <div> with the above inline styles. Avoid markdown.
""")

    def write_raw_node(self, zone, name, content):
        filepath = os.path.join(self.base_dir, zone, f"{name}.jcross")
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(content)

    def write_generated_node(self, zone, cognition_text):
        if not cognition_text: return
        node_id = str(uuid.uuid4())[:8]
        filepath = os.path.join(self.base_dir, zone, f"tm_{node_id}.jcross")
        
        # Replace the generic NODE_current with the new ID
        cognition_text = cognition_text.replace("JCROSS_NODE_current", f"JCROSS_NODE_{node_id}")
        
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"{cognition_text}\n")
        print(f"[System] Cortex Node Crystallized: {filepath}")

    def load_zone(self, zone):
        zone_dir = os.path.join(self.base_dir, zone)
        nodes = []
        for filename in os.listdir(zone_dir):
            if filename.endswith(".jcross"):
                with open(os.path.join(zone_dir, filename), "r", encoding="utf-8") as f:
                    nodes.append(f.read())
        return nodes
        
    def get_front_injection(self):
        active_nodes = self.load_zone("front")
        return "\n\n".join(active_nodes)
        
    def search_jcross(self, query):
        """
        Simulates the Rust query_jcross logic by scanning [本質記憶] blocks in 'near' zone.
        """
        near_nodes = self.load_zone("near")
        for node in near_nodes:
            # Extract essential memory block
            match = re.search(r"\[本質記憶\](.*)", node, re.DOTALL)
            if match:
                essence = match.group(1)
                if query.lower() in essence.lower():
                    # Extract the translation from the response format
                    trans_match = re.search(r"Translation:\s*(.*)", essence)
                    if trans_match:
                        return trans_match.group(1).strip()
        return None

    def migrate_memory(self):
        """
        Simulates Verantyx memory migration: near -> mid -> deep
        """
        near_dir = os.path.join(self.base_dir, "near")
        mid_dir = os.path.join(self.base_dir, "mid")
        deep_dir = os.path.join(self.base_dir, "deep")
        
        # Move older near nodes to mid
        near_files = sorted(os.listdir(near_dir))
        if len(near_files) > 5:
            for f in near_files[:-5]:
                shutil.move(os.path.join(near_dir, f), os.path.join(mid_dir, f))
                
        # Move older mid nodes to deep
        mid_files = sorted(os.listdir(mid_dir))
        if len(mid_files) > 20:
            for f in mid_files[:-20]:
                shutil.move(os.path.join(mid_dir, f), os.path.join(deep_dir, f))

memory_engine = AuthenticJCrossMemory()

# ==========================================
# 2. Multi-Agent Dual-LLM Loading
# ==========================================
MODERN_MODEL_ID = "Qwen/Qwen2.5-3B-Instruct"
HISTORICAL_MODEL_ID = "talkie-1930-13b-it"

modern_tokenizer = None
modern_model = None
historical_model = None
model_load_lock = threading.Lock()

def load_modern():
    global modern_tokenizer, modern_model
    if modern_model is None:
        print(f"[Modern Agent] Loading {MODERN_MODEL_ID}...")
        modern_tokenizer = AutoTokenizer.from_pretrained(MODERN_MODEL_ID)
        modern_model = AutoModelForCausalLM.from_pretrained(
            MODERN_MODEL_ID, 
            device_map="auto", 
            torch_dtype=torch.float16,
            low_cpu_mem_usage=True
        )

def unload_modern():
    global modern_tokenizer, modern_model
    modern_model = None
    modern_tokenizer = None
    gc.collect()
    if torch.cuda.is_available(): torch.cuda.empty_cache()
    if torch.backends.mps.is_available(): torch.mps.empty_cache()

def load_historical():
    global historical_model
    if historical_model is None:
        device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
        print(f"[Historical Agent] Loading {HISTORICAL_MODEL_ID}...")
        historical_model = Talkie(HISTORICAL_MODEL_ID, device=device)

def unload_historical():
    global historical_model
    historical_model = None
    gc.collect()
    if torch.cuda.is_available(): torch.cuda.empty_cache()
    if torch.backends.mps.is_available(): torch.mps.empty_cache()

# ==========================================
# 3. Verantyx V7 Loop (Agents)
# ==========================================
class V7TranslatorAgent:
    SYSTEM_PROMPT = """[System Directive]
You are Verantyx Cortex (V7 Edition) Conceptual Translator.
You must take a modern technological or social concept and translate it into an equivalent 1930s paradigm.
AND compress your translation into a JCross physics node.
Everything is an equal tagged #Entity.

[Output Format]
<jcross_cognition>
■ JCROSS_NODE_current
【空間座相】 [Z:0]
【次元概念】 (List all entities starting with # e.g. #Modern #1930s)
【操作軌道】 
[本質記憶]
//! Translation: {Modern Word} -> {Translated 1930s Word}
</jcross_cognition>

<response>
(Your translated 1930s concept here, max 2 sentences)
</response>
"""

    @staticmethod
    def abstract_concept(news_text):
        # Rust Engine Query Simulator
        past_translation = memory_engine.search_jcross(news_text)
        if past_translation:
            return past_translation.split("->")[-1].strip() + " (Recalled from JCross)"
            
        messages = [
            {"role": "system", "content": V7TranslatorAgent.SYSTEM_PROMPT},
            {"role": "user", "content": f"Modern concept: {news_text}"}
        ]
        
        text = modern_tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        inputs = modern_tokenizer([text], return_tensors="pt").to(modern_model.device)
        
        outputs = modern_model.generate(
            inputs.input_ids,
            max_new_tokens=300,
            temperature=0.2,
            do_sample=True,
        )
        
        output_ids = outputs[0][len(inputs.input_ids[0]):]
        full_output = modern_tokenizer.decode(output_ids, skip_special_tokens=True).strip()
        
        # Authentic parsing from v7_unified_loop.py
        cognition_match = re.search(r"<jcross_cognition>(.*?)</jcross_cognition>", full_output, re.DOTALL)
        response_match = re.search(r"<response>(.*?)</response>", full_output, re.DOTALL)
        
        cognition_block = cognition_match.group(1).strip() if cognition_match else None
        response_block = response_match.group(1).strip() if response_match else full_output
        
        if cognition_block:
            memory_engine.write_generated_node("near", cognition_block)
            
        return response_block

class HistoricalReporterAgent:
    @staticmethod
    def generate_article(abstracted_event):
        dynamic_jcross = memory_engine.get_front_injection()
        system_prompt = (
            "You are a first-class newspaper reporter in the 1930s.\n\n"
            "=== ACTIVE JCROSS SPATIAL MEMORY ===\n"
            f"{dynamic_jcross}\n"
            "====================================\n\n"
            "Based on the 'Event', output a newspaper article in raw HTML incorporating the Dictionary rules. "
            "Do NOT output markdown. Use dramatic, period-accurate 1930s Anglo-American language."
        )
        
        messages = [
            TalkieMessage(role="system", content=system_prompt),
            TalkieMessage(role="user", content=f"Event: {abstracted_event}")
        ]
        
        result = historical_model.chat(
            messages,
            temperature=0.7,
            max_tokens=1500,
            top_p=0.9
        )
        return result.text.strip().replace("```html", "").replace("```", "")

class Orchestrator:
    def process(self, news_text):
        with model_load_lock:
            yield "Abstracting Concept (V7 JCross Matrix)...", "<div>Booting translation matrix...</div>"
            load_modern()
            abstracted = V7TranslatorAgent.abstract_concept(news_text)
            unload_modern()
            
            yield abstracted, "<div style='color: #888;'>Concept translated. Injecting JCross to Historical Generator...</div>"
            
            load_historical()
            html_article = HistoricalReporterAgent.generate_article(abstracted)
            unload_historical()
            
            # Migrate memory: near -> mid -> deep
            memory_engine.migrate_memory()
            
            yield abstracted, html_article

orchestrator = Orchestrator()

def ui_handler(news_text):
    if not news_text:
        yield "Please enter a news item.", "<div>Please enter a news item.</div>"
        return
    for result in orchestrator.process(news_text):
        yield result

# ==========================================
# 4. UI Setup
# ==========================================
with gr.Blocks(theme=gr.themes.Monochrome(), title="Authentic Verantyx V7 Proxy") as app:
    gr.Markdown("# 🧠 Authentic Verantyx V7 Multi-Agent Pipeline")
    gr.Markdown("This implementation uses the **Authentic JCross V7 Architecture** (`v7_unified_loop.py`). The Modern LLM outputs raw `<jcross_cognition>` blocks containing spatial coordinates (`【空間座相】`), which are crystallized into physical `.jcross` text files before generating the 1930s paper.")
    
    with gr.Row():
        with gr.Column(scale=2):
            news_input = gr.Textbox(label="Current News", lines=2)
            generate_btn = gr.Button("⚙️ Execute V7 Loop", variant="primary")
            abstract_output = gr.Textbox(label="Historical Concept", interactive=False, lines=2)
        with gr.Column(scale=3):
            article_output = gr.HTML(label="1930s Newspaper Layout")
            
    generate_btn.click(fn=ui_handler, inputs=[news_input], outputs=[abstract_output, article_output])

if __name__ == "__main__":
    app.launch(server_name="0.0.0.0", server_port=7860, share=False)
