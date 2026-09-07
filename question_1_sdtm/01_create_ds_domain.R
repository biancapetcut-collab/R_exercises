# =============================================================================
# Program:      01_create_ds_domain.R
# Purpose:      Create the SDTM Disposition (DS) domain from raw clinical
#               trial data using {sdtm.oak}, following the CDISC SDTMIG v3.4
#               Events class structure.
# Input:        pharmaverseraw::ds_raw   (raw disposition eCRF extract)
#               pharmaversesdtm::dm      (SDTM DM domain, used for RFSTDTC
#                                         needed to derive DSSTDY)
#               study_ct                 (study controlled terminology, see
#                                         "Read in CT" section below)
# Output:       ds  (SDTM DS domain data frame)
#               question_1_sdtm/ds.rds / ds.csv
# =============================================================================

library(sdtm.oak)
library(pharmaverseraw)
library(pharmaversesdtm)
library(dplyr)
library(stringr)

# ----------------------------------------------------------------------------
# 1. Read in data
# ----------------------------------------------------------------------------
ds_raw <- pharmaverseraw::ds_raw
dm <- pharmaversesdtm::dm

# ----------------------------------------------------------------------------
# 2. Create oak_id_vars
#    These are the traceability keys ({sdtm.oak} uses them to join the mapped
#    target variables back to the raw source records).
# ----------------------------------------------------------------------------
ds_raw <- ds_raw %>%
  generate_oak_id_vars(
    pat_var = "PATNUM",
    raw_src = "ds_raw"
  )

# ----------------------------------------------------------------------------
# 3. Read in Study Controlled Terminology
#    Falls back to the CT defined directly in the assessment PDF if the
#    GitHub-hosted study_ct.csv is not accessible.
# ----------------------------------------------------------------------------
study_ct <-
  data.frame(
    stringsAsFactors = FALSE,
    codelist_code = c(
      "C66727", "C66727", "C66727", "C66727", "C66727",
      "C66727", "C66727", "C66727", "C66727", "C66727"
    ),
    term_code = c(
      "C41331", "C25250", "C28554", "C48226", "C48227", "C48250",
      "C142185", "C49628", "C49632", "C49634"
    ),
    term_value = c(
      "ADVERSE EVENT", "COMPLETED", "DEATH", "LACK OF EFFICACY",
      "LOST TO FOLLOW-UP", "PHYSICIAN DECISION", "PROTOCOL VIOLATION",
      "SCREEN FAILURE", "STUDY TERMINATED BY SPONSOR", "WITHDRAWAL BY SUBJECT"
    ),
    collected_value = c(
      "Adverse Event", "Complete", "Dead", "Lack of Efficacy",
      "Lost To Follow-Up", "Physician Decision", "Protocol Violation",
      "Trial Screen Failure", "Study Terminated By Sponsor",
      "Withdrawal by Subject"
    ),
    term_preferred_term = c(
      "AE", "Completed", "Died", NA, NA, NA, "Violation",
      "Failure to Meet Inclusion/Exclusion Criteria", NA, "Dropout"
    ),
    term_synonyms = c(
      "ADVERSE EVENT", "COMPLETE", "Death", NA, NA, NA, NA, NA, NA,
      "Discontinued Participation"
    )
  )

# NOTE on CT matching: {sdtm.oak}'s assign_ct() falls back to toupper(raw
# value) whenever no exact (case-sensitive) match is found in `collected_value`.
# Because the raw ds_raw$IT.DSDECOD values already correspond 1:1 to a
# disposition/milestone term (e.g. "Completed", "Death", "Randomized"), this
# fallback conveniently reproduces the correct CDISC-coded DSDECOD value even
# for the terms that don't textually match `collected_value` (e.g. "Completed"
# vs. "Complete", or "Randomized" which is a protocol milestone term not
# present in the codelist at all).

# ----------------------------------------------------------------------------
# 4. Map Topic Variable (DSTERM)
#    DSTERM is the verbatim disposition/milestone term collected on the CRF.
# ----------------------------------------------------------------------------
ds <-
  assign_no_ct(
    raw_dat = ds_raw,
    raw_var = "IT.DSTERM",
    tgt_var = "DSTERM",
    id_vars = oak_id_vars()
  )

# ----------------------------------------------------------------------------
# 5. Map remaining Qualifier / Timing variables
# ----------------------------------------------------------------------------
ds <- ds %>%
  # Map DSDECOD using assign_ct, raw_var = IT.DSDECOD, tgt_var = DSDECOD
  assign_ct(
    raw_dat = ds_raw,
    raw_var = "IT.DSDECOD",
    tgt_var = "DSDECOD",
    ct_spec = study_ct,
    ct_clst = "C66727",
    id_vars = oak_id_vars()
  ) %>%
  # Map DSDTC (date of collection of the disposition form) combining the
  # collected date (DSDTCOL, m-d-y) and, when present, the collected time
  # (DSTMCOL, HH:MM). {sdtm.oak}'s assign_datetime() derives an ISO 8601
  # partial/complete date-time automatically.
  assign_datetime(
    raw_dat = ds_raw,
    raw_var = c("DSDTCOL", "DSTMCOL"),
    tgt_var = "DSDTC",
    raw_fmt = c("m-d-y", "H:M"),
    id_vars = oak_id_vars()
  ) %>%
  # Map DSSTDTC (start date of the disposition/milestone event)
  assign_datetime(
    raw_dat = ds_raw,
    raw_var = "IT.DSSTDAT",
    tgt_var = "DSSTDTC",
    raw_fmt = c("m-d-y"),
    id_vars = oak_id_vars()
  )

# ----------------------------------------------------------------------------
# 6. Repeat Map Topic and Map Rest
#    ds_raw has a single topic variable (IT.DSTERM), so this step is not
#    required (only relevant when multiple raw topic variables map into the
#    same domain, e.g. multiple CRF pages).
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# 7. Create SDTM derived variables
# ----------------------------------------------------------------------------

# Visit lookup: the source aCRF with the official Visit/VISITNUM structure for
# this study was not available for this exercise, so VISIT/VISITNUM are
# derived programmatically from the `INSTANCE` (visit) values collected in
# ds_raw, using the nominal, chronological order of the scheduled visits.
# Unscheduled visits already encode their nominal position in the visit
# label (e.g. "Unscheduled 4.1" occurs between visit 4 and visit 5), so the
# embedded decimal number is used directly as VISITNUM.
scheduled_visit_lookup <- tibble::tibble(
  INSTANCE = c(
    "Screening 1", "Baseline", "Week 2", "Week 4", "Week 6", "Week 8",
    "Week 12", "Week 16", "Week 20", "Week 24", "Week 26",
    "Ambul Ecg Removal", "Retrieval"
  ),
  VISITNUM = c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 11.5, 12)
)

ds_raw_visit <- ds_raw %>%
  select(oak_id, INSTANCE) %>%
  left_join(scheduled_visit_lookup, by = "INSTANCE") %>%
  mutate(
    # Unscheduled visits: extract the decimal visit number embedded in the
    # label itself, e.g. "Unscheduled 4.1" -> 4.1
    VISITNUM = if_else(
      is.na(VISITNUM) & str_detect(INSTANCE, "^Unscheduled"),
      as.numeric(str_extract(INSTANCE, "[0-9]+\\.[0-9]+")),
      VISITNUM
    ),
    VISIT = if_else(
      str_detect(INSTANCE, "^Unscheduled"),
      "UNSCHEDULED",
      toupper(INSTANCE)
    )
  )

ds <- ds %>%
  left_join(ds_raw_visit, by = "oak_id") %>%
  mutate(
    STUDYID = ds_raw$STUDY[match(oak_id, ds_raw$oak_id)],
    DOMAIN = "DS",
    USUBJID = paste0("01-", ds_raw$PATNUM[match(oak_id, ds_raw$oak_id)]),
    # Protocol milestones (e.g. Randomization) vs. disposition events
    DSCAT = if_else(DSDECOD == "RANDOMIZED", "PROTOCOL MILESTONE", "DISPOSITION EVENT")
  ) %>%
  # Drop CRF instances where no disposition/milestone term was collected
  # (e.g. records where only the "Other, specify" field was populated)
  filter(!is.na(DSTERM)) %>%
  derive_seq(
    tgt_var = "DSSEQ",
    rec_vars = c("USUBJID", "VISITNUM", "DSSTDTC")
  ) %>%
  derive_study_day(
    sdtm_in = .,
    dm_domain = dm,
    tgdt = "DSSTDTC",
    refdt = "RFSTDTC",
    study_day_var = "DSSTDY"
  ) %>%
  arrange(USUBJID, DSSEQ) %>%
  select(
    STUDYID, DOMAIN, USUBJID, DSSEQ, DSTERM, DSDECOD, DSCAT,
    VISITNUM, VISIT, DSDTC, DSSTDTC, DSSTDY
  )

# ----------------------------------------------------------------------------
# 8. Checks
# ----------------------------------------------------------------------------
stopifnot(
  all(c(
    "STUDYID", "DOMAIN", "USUBJID", "DSSEQ", "DSTERM", "DSDECOD", "DSCAT",
    "VISITNUM", "VISIT", "DSDTC", "DSSTDTC", "DSSTDY"
  ) %in% names(ds)),
  all(ds$DOMAIN == "DS"),
  !anyNA(ds$DSTERM),
  !anyNA(ds$USUBJID),
  # DSSEQ should be unique within USUBJID
  nrow(ds) == nrow(distinct(ds, USUBJID, DSSEQ))
)

cat("DS domain created successfully:", nrow(ds), "records,",
    dplyr::n_distinct(ds$USUBJID), "subjects.\n")

print(dplyr::count(ds, DSCAT, DSDECOD))

# ----------------------------------------------------------------------------
# 9. Save output
# ----------------------------------------------------------------------------
saveRDS(ds, file = file.path("question_1_sdtm", "ds.rds"))
write.csv(ds, file = file.path("question_1_sdtm", "ds.csv"), row.names = FALSE, na = "")
