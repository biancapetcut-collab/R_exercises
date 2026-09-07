# R Coding Exercise

This repository contains solutions to R coding exercises: three required Pharmaverse (SDTM/ADaM/TLG) exercises in R, plus
a bonus Python GenAI exercise.

## Repository structure

```
.
├── question_1_sdtm/     # Q1: SDTM DS domain creation using {sdtm.oak}
├── question_2_adam/     # Q2: ADaM ADSL dataset creation using {admiral}
├── question_3_tlg/      # Q3: AE summary table (gtsummary) + ggplot2 visualizations
└── question_4_python/   # Q4 (bonus): GenAI Clinical Data Assistant (Python)
```

Each `question_*` folder is self-contained: script(s), the resulting
dataset/output file(s), and a run log confirming error-free execution.

---

## Question 1 — `question_1_sdtm/`

**Script:** `01_create_ds_domain.R`
**Output:** `ds.rds` / `ds.csv` (SDTM DS domain, 560 records / 306 subjects)
**Log:** `01_run_log.txt`

Creates the SDTM Disposition (DS) domain from `pharmaverseraw::ds_raw` using
`{sdtm.oak}`, following the same Events-domain mapping pattern as the AE
example in the Pharmaverse Examples site (`generate_oak_id_vars()` →
`assign_no_ct()`/`assign_ct()`/`assign_datetime()` → derived variables →
`derive_seq()`/`derive_study_day()`).

Key assumptions (documented in code comments):
- The study controlled terminology (`study_ct`) uses the fallback data frame
  given directly in the assessment PDF (option 3), since the CT was
  reproduced as an exact literal in the instructions.
- `DSCAT` is set to `"PROTOCOL MILESTONE"` for `DSDECOD == "RANDOMIZED"` and
  `"DISPOSITION EVENT"` otherwise.
- `VISIT`/`VISITNUM` are derived from the raw `INSTANCE` (visit) values using
  the nominal chronological order of scheduled visits, because the source
  aCRF defining the official visit structure was not available for this
  exercise. Unscheduled visits use the decimal visit number already
  embedded in their label (e.g. `"Unscheduled 4.1"` → `VISITNUM = 4.1`).
- Records where no disposition/milestone term was collected (only an
  "Other, specify" free-text field populated) are excluded from the domain.

## Question 2 — `question_2_adam/`

**Script:** `create_adsl.R`
**Output:** `adsl.rds` / `adsl.csv` (ADSL, 306 subjects / 51 variables)
**Log:** `create_adsl_log.txt`

Creates the ADSL dataset from `pharmaversesdtm::dm/vs/ex/ds/ae` using
`{admiral}`, following the Pharmaverse "Creating ADSL" example (treatment
variables, TRTSDTM/TRTEDTM, disposition variables, age, death variables,
population flags), extended with the four custom variables required by the
exercise:

| Variable | Derivation approach |
|---|---|
| `AGEGR9` / `AGEGR9N` | `derive_vars_cat()` with a lookup table: `<18` (1), `18 - 50` (2), `>50` (3), based on `DM.AGE`. |
| `TRTSDTM` / `TRTSTMF` (+ `TRTEDTM`/`TRTETMF`) | `derive_vars_dtm(highest_imputation = "h", time_imputation = "00:00:00")` on `EX.EXSTDTC`/`EXENDTC`, restricted to valid-dose records, merged first/last per subject. Admiral's default `ignore_seconds_flag = TRUE` ensures the imputation flag is *not* set when only seconds are missing, per the spec. |
| `ITTFL` | `"Y"` if `DM.ARM` is populated, else `"N"`. |
| `LSTAVLDT` | `derive_vars_extreme_event()` taking the max of last complete VS date (valid result), last complete AE onset date, last complete DS disposition date, and `TRTEDT` (datepart of `TRTEDTM`). |

## Question 3 — `question_3_tlg/`

**Scripts:** `01_create_ae_summary_table.R`, `02_create_visualizations.R`
**Outputs:**
- `ae_summary_table.html` — FDA Table 10–style TEAE summary table
- `plot1_ae_severity_by_treatment.png` — AE severity distribution by treatment
- `plot2_top10_ae_frequency.png` — Top 10 most frequent AEs with 95% Clopper-Pearson CIs
**Logs:** `01_run_log.txt`, `02_run_log.txt`

Uses `pharmaverseadam::adae`/`adsl`. The summary table uses gtsummary's
`tbl_hierarchical()` (AESOC → AETERM hierarchy, stratified by `ACTARM`,
denominators from `adsl`, `add_overall()` for the Total column,
`sort_hierarchical()` for descending-frequency sorting). Plot 1 uses all AE
records; Plot 2 restricts the denominator to the 225 unique subjects with
at least one AE (matching the sample output in the assessment) and computes
exact (Clopper-Pearson) 95% CIs with `{binom}`.

## Question 4 (bonus) — `question_4_python/`

**Script:** `clinical_trial_data_agent.py` (agent) + `test_agent.py` (3 example queries)
**Data:** `data/adae.csv` (exported from `pharmaversesdtm::ae`)
**Log:** `test_run_log.txt`

Implements `ClinicalTrialDataAgent`, which maps a free-text safety-reviewer
question to a Pandas filter via the **Prompt → Parse → Execute** pipeline:

1. **Prompt** (`build_prompt`): embeds a schema *description* of the
   relevant AE columns (`AETERM`, `AEDECOD`, `AESOC`, `AESEV`, `AESER`,
   `AEREL`, `AEOUT`) and the user's question, asking for a structured JSON
   response (`target_column`, `filter_value`).
2. **Parse** (`parse_llm_response`): validates and extracts the JSON payload.
3. **Execute** (`execute_query`): applies the parsed filter (case-insensitive
   substring match) to the AE dataframe with Pandas and returns the count of
   unique subjects (`USUBJID`) plus the list of matching subject IDs.

If `OPENAI_API_KEY` is set, a real call is made via
`langchain-openai`'s `ChatOpenAI`. Otherwise the LLM call is transparently
mocked (`_mock_llm_call`) — the mock reasons over the same column
*descriptions* given to a real LLM (not a question → column lookup table),
so the full pipeline can be demonstrated without network/API access, per
the assessment's guidance.

Run the demo:
```bash
cd question_4_python
pip install -r requirements.txt   # pandas always; langchain packages only if using a real key
python3 test_agent.py
```

---

## Environment

- R 4.6.1 (Posit Cloud); packages: `sdtm.oak`, `admiral`, `pharmaverseraw`,
  `pharmaversesdtm`, `pharmaverseadam`, `gtsummary`, `gt`, `dplyr`, `tidyr`,
  `ggplot2`, `lubridate`, `stringr`, `binom`, `forcats`.
- Python 3.12; packages: `pandas` (plus optionally `langchain-openai`,
  `langchain-core` for a real LLM call).
