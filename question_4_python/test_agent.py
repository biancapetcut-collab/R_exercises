"""
test_agent.py

Simple test script that runs three example natural-language queries through
the ClinicalTrialDataAgent and prints the results.

Run with:  python3 test_agent.py
"""

import json

from clinical_trial_data_agent import ClinicalTrialDataAgent

EXAMPLE_QUESTIONS = [
    "Give me the subjects who had Adverse events of Moderate severity",
    "Which patients reported Headache?",
    "Show me subjects with adverse events in the Cardiac system organ class",
]


def main() -> None:
    agent = ClinicalTrialDataAgent.from_csv()

    for i, question in enumerate(EXAMPLE_QUESTIONS, start=1):
        print(f"\n{'=' * 80}\nQuery {i}: {question}\n{'=' * 80}")
        print(f"Prompt sent to LLM:\n{agent.last_prompt if False else build_prompt_preview(question)}")

        result = agent.answer(question)

        print(f"\nRaw LLM response: {agent.last_llm_response}")
        print(f"Parsed -> target_column = {result['target_column']!r}, "
              f"filter_value = {result['filter_value']!r}")
        print(f"\nMatching AE records: {result['n_records']}")
        print(f"Unique subjects (USUBJID) with this AE: {result['n_unique_subjects']}")
        print(f"Subject IDs: {result['subject_ids']}")


def build_prompt_preview(question: str) -> str:
    from clinical_trial_data_agent import build_prompt

    prompt = build_prompt(question)
    # Print an abbreviated version for readability in the console.
    return prompt.split("\n\nQuestion:")[0][:200] + " ... [schema truncated]"


if __name__ == "__main__":
    main()
