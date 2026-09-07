# =============================================================================
# Program:      01_create_ae_summary_table.R
# Purpose:      Create a summary table of Treatment-Emergent Adverse Events
#               (TEAEs) by treatment arm, following the FDA Table 10 layout,
#               using {gtsummary}'s tbl_hierarchical().
# Input:        pharmaverseadam::adae, pharmaverseadam::adsl
# Output:       question_3_tlg/ae_summary_table.html
# =============================================================================

library(dplyr)
library(gtsummary)
library(gt)
library(pharmaverseadam)

# ----------------------------------------------------------------------------
# 1. Read in data
# ----------------------------------------------------------------------------
adae <- pharmaverseadam::adae
adsl <- pharmaverseadam::adsl

# Treatment-emergent AE records only
teae <- adae %>%
  filter(TRTEMFL == "Y")

cat("Number of TEAE records:", nrow(teae), "\n")
cat("Number of unique subjects with a TEAE:", n_distinct(teae$USUBJID), "\n")

# ----------------------------------------------------------------------------
# 2. Build the hierarchical AE summary table
#    - Hierarchy: AESOC (Primary System Organ Class) -> AETERM (Preferred/
#      Reported Term)
#    - Columns: ACTARM (actual treatment arm), stratified counts n (%)
#    - denominator = adsl provides the per-arm subject totals (column headers)
#    - overall_row = TRUE adds a "Treatment Emergent AEs" summary row (any AE)
# ----------------------------------------------------------------------------
ae_tbl <- tbl_hierarchical(
  data = teae,
  variables = c(AESOC, AETERM),
  by = ACTARM,
  denominator = adsl,
  id = USUBJID,
  statistic = everything() ~ "{n} ({p}%)",
  digits = everything() ~ list(p = 1),
  overall_row = TRUE,
  label = list(
    AESOC = "Primary System Organ Class",
    AETERM = "Reported Term for the Adverse Event",
    ..ard_hierarchical_overall.. = "Treatment Emergent AEs"
  )
) %>%
  # Add a "Total" column across all subjects
  add_overall(last = TRUE) %>%
  # Sort AESOC and AETERM rows by descending frequency (default behaviour)
  sort_hierarchical() %>%
  modify_header(label = "**Primary System Organ Class**  \n**Reported Term for the Adverse Event**") %>%
  modify_caption("**Table 10: Treatment-Emergent Adverse Events by System Organ Class and Preferred Term**") %>%
  bold_labels()

# ----------------------------------------------------------------------------
# 3. Checks
# ----------------------------------------------------------------------------
stopifnot(inherits(ae_tbl, "tbl_hierarchical"))
stopifnot(nrow(ae_tbl$table_body) > 0)

# ----------------------------------------------------------------------------
# 4. Render and save output
# ----------------------------------------------------------------------------
ae_gt <- as_gt(ae_tbl)

gt::gtsave(ae_gt, filename = file.path("question_3_tlg", "ae_summary_table.html"))

cat("\nAE summary table saved to question_3_tlg/ae_summary_table.html\n")
cat("Table has", nrow(ae_tbl$table_body), "rows.\n")
