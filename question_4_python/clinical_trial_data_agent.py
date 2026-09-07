"""
clinical_trial_data_agent.py

GenAI Clinical Data Assistant (LLM & LangChain).

Translates a clinical safety reviewer's free-text question about the AE
dataset (adae.csv, sourced from pharmaversesdtm::ae) into a structured
Pandas query, using an LLM to map user intent to the correct dataset
variable -- without hard-coding a lookup of keyword -> column rules.

Logic flow:  Prompt -> Parse -> Execute
    1. Prompt:   build_prompt() embeds a schema description of the AE
                 dataset and the user's question into an LLM prompt asking
                 for a structured JSON response.
    2. Parse:    parse_llm_response() validates/parses the JSON payload
                 into {target_column, filter_value}.
    3. Execute:  execute_query() applies the parsed filter to the AE
                 dataframe with pandas and returns the count of unique
                 subjects (USUBJID) and the list of matching subject IDs.

If an OpenAI API key is available (OPENAI_API_KEY environment variable),
a real LLM call is made via LangChain's ChatOpenAI. Otherwise, the LLM
call is transparently mocked (see `_mock_llm_call`) so the full
Prompt -> Parse -> Execute flow can still be demonstrated end-to-end
without network access or an API key.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from typing import Any

import pandas as pd

DATA_PATH = os.path.join(os.path.dirname(__file__), "data", "adae.csv")

# -----------------------------------------------------------------------
# 1. Schema Definition
# -----------------------------------------------------------------------
# A description of the relevant AE columns, given to the LLM so that it
# can map free-text concepts (e.g. "severity", "a body system") to the
# correct dataset variable. This is *not* a keyword -> column lookup; it
# is descriptive metadata that the LLM itself uses to reason about intent.
AE_SCHEMA: dict[str, str] = {
    "AETERM": (
        "Verbatim/reported term for the adverse event as described by the "
        "investigator, e.g. 'HEADACHE', 'NAUSEA', 'APPLICATION SITE "
        "PRURITUS'. Use this column when the question refers to a specific "
        "medical condition, symptom, or diagnosis."
    ),
    "AEDECOD": (
        "MedDRA Preferred Term (standardized/coded version of AETERM), "
        "e.g. 'HEADACHE'. Use this column when the question asks for a "
        "standardized/coded adverse event term rather than the verbatim term."
    ),
    "AESOC": (
        "MedDRA Primary System Organ Class -- the body system or organ "
        "class affected, e.g. 'CARDIAC DISORDERS', 'SKIN AND SUBCUTANEOUS "
        "TISSUE DISORDERS', 'GASTROINTESTINAL DISORDERS'. Use this column "
        "when the question refers to a body system, organ class, or "
        "general category of adverse events (e.g. 'cardiac', 'skin')."
    ),
    "AESEV": (
        "Severity/intensity of the adverse event: one of 'MILD', "
        "'MODERATE', 'SEVERE'. Use this column when the question refers "
        "to severity, intensity, or how bad/strong an adverse event was."
    ),
    "AESER": (
        "Whether the adverse event was serious: 'Y' or 'N'. Use this "
        "column when the question asks about seriousness of an event."
    ),
    "AEREL": (
        "Causality/relationship of the adverse event to study treatment, "
        "e.g. 'RELATED', 'NOT RELATED'. Use this column when the question "
        "asks whether an event was related/caused by the study drug."
    ),
    "AEOUT": (
        "Outcome of the adverse event, e.g. 'RECOVERED/RESOLVED', "
        "'FATAL', 'NOT RECOVERED/NOT RESOLVED'. Use this column when the "
        "question asks about the outcome or resolution of an event."
    ),
}

REQUIRED_KEYS = {"target_column", "filter_value"}


def build_schema_description() -> str:
    """Render the AE_SCHEMA dictionary as a bullet-point string for the LLM prompt."""
    return "\n".join(f"- {col}: {desc}" for col, desc in AE_SCHEMA.items())


def build_prompt(question: str) -> str:
    """Construct the LLM prompt: dataset schema + user question + output format."""
    schema_description = build_schema_description()
    return f"""You are a clinical data assistant. You have access to an adverse
event (AE) dataset with the following relevant columns:

{schema_description}

A clinical safety reviewer has asked the following free-text question. Your
job is to identify which single column of the dataset should be filtered on,
and what value to filter for, in order to answer the question.

Question: "{question}"

Respond with ONLY a JSON object (no other text) in this exact format:
{{"target_column": "<one of the column names above>", "filter_value": "<value extracted from the question>"}}
"""


# -----------------------------------------------------------------------
# 2. LLM call (real or mocked) + Parse
# -----------------------------------------------------------------------
def _call_real_llm(prompt: str, model: str = "gpt-4o-mini") -> str:
    """Call OpenAI via LangChain. Requires OPENAI_API_KEY to be set."""
    from langchain_openai import ChatOpenAI
    from langchain_core.messages import HumanMessage

    llm = ChatOpenAI(model=model, temperature=0)
    response = llm.invoke([HumanMessage(content=prompt)])
    return response.content


def _mock_llm_call(prompt: str, question: str) -> str:
    """
    Stand-in for the LLM call when no API key is configured.

    NOTE: This mock exists purely so the Prompt -> Parse -> Execute pipeline
    can be demonstrated without network/API access, per the assessment's
    guidance ("you may mock the LLM response ... but the logic flow must be
    complete"). It approximates what an LLM equipped with the AE_SCHEMA
    description above would return, by semantically matching the question
    against the schema's column *descriptions* (not a hard-coded
    question -> column lookup) and extracting the most plausible value
    (typically the capitalized noun phrase in the question).
    """
    q_lower = question.lower()

    # Score each column by counting how many description words appear in
    # the question (a crude stand-in for the LLM's semantic reasoning).
    best_col, best_score = "AETERM", 0
    for col, desc in AE_SCHEMA.items():
        desc_words = set(re.findall(r"[a-z]+", desc.lower()))
        q_words = set(re.findall(r"[a-z]+", q_lower))
        score = len(desc_words & q_words)
        if score > best_score:
            best_col, best_score = col, score

    # Extract a plausible filter value: prefer a quoted phrase, else the
    # longest capitalized word/phrase in the original question, else the
    # last word.
    quoted = re.findall(r"['\"]([^'\"]+)['\"]", question)
    capitalized = re.findall(r"\b[A-Z][a-zA-Z]+\b", question)
    if quoted:
        filter_value = quoted[0]
    elif capitalized:
        filter_value = max(capitalized, key=len)
    else:
        filter_value = question.strip().split()[-1].strip("?.!")

    return json.dumps({"target_column": best_col, "filter_value": filter_value})


def call_llm(prompt: str, question: str) -> str:
    """Dispatch to the real LLM if an API key is available, else the mock."""
    if os.environ.get("OPENAI_API_KEY"):
        try:
            return _call_real_llm(prompt)
        except Exception as exc:  # pragma: no cover - network/env dependent
            print(f"[warning] Real LLM call failed ({exc}); falling back to mock.")
    return _mock_llm_call(prompt, question)


def parse_llm_response(raw_response: str) -> dict[str, str]:
    """Parse and validate the LLM's JSON response into {target_column, filter_value}."""
    match = re.search(r"\{.*\}", raw_response, re.DOTALL)
    if not match:
        raise ValueError(f"No JSON object found in LLM response: {raw_response!r}")

    parsed = json.loads(match.group(0))

    missing = REQUIRED_KEYS - parsed.keys()
    if missing:
        raise ValueError(f"LLM response missing required keys: {missing}")

    if parsed["target_column"] not in AE_SCHEMA:
        raise ValueError(
            f"LLM returned an unknown target_column: {parsed['target_column']!r}. "
            f"Expected one of {list(AE_SCHEMA)}."
        )

    return {
        "target_column": parsed["target_column"],
        "filter_value": str(parsed["filter_value"]),
    }


# -----------------------------------------------------------------------
# 3. Execute
# -----------------------------------------------------------------------
def execute_query(ae: pd.DataFrame, parsed: dict[str, str]) -> dict[str, Any]:
    """Apply the parsed {target_column, filter_value} as a case-insensitive,
    substring Pandas filter on the AE dataframe, and return the count of
    unique subjects and the list of matching subject IDs."""
    col = parsed["target_column"]
    value = parsed["filter_value"]

    mask = ae[col].astype(str).str.contains(value, case=False, na=False, regex=False)
    matches = ae.loc[mask]

    subject_ids = sorted(matches["USUBJID"].unique().tolist())
    return {
        "target_column": col,
        "filter_value": value,
        "n_records": int(mask.sum()),
        "n_unique_subjects": len(subject_ids),
        "subject_ids": subject_ids,
    }


# -----------------------------------------------------------------------
# ClinicalTrialDataAgent
# -----------------------------------------------------------------------
@dataclass
class ClinicalTrialDataAgent:
    """Agent that answers free-text questions about an AE dataframe."""

    ae: pd.DataFrame
    last_prompt: str | None = field(default=None, init=False)
    last_llm_response: str | None = field(default=None, init=False)
    last_parsed: dict[str, str] | None = field(default=None, init=False)

    @classmethod
    def from_csv(cls, path: str = DATA_PATH) -> "ClinicalTrialDataAgent":
        return cls(ae=pd.read_csv(path))

    def answer(self, question: str) -> dict[str, Any]:
        """Run the full Prompt -> Parse -> Execute pipeline for one question."""
        self.last_prompt = build_prompt(question)
        self.last_llm_response = call_llm(self.last_prompt, question)
        self.last_parsed = parse_llm_response(self.last_llm_response)
        result = execute_query(self.ae, self.last_parsed)
        result["question"] = question
        return result


if __name__ == "__main__":
    agent = ClinicalTrialDataAgent.from_csv()
    demo_result = agent.answer("Give me the subjects who had Adverse events of Moderate severity")
    print(json.dumps(demo_result, indent=2)[:500])
