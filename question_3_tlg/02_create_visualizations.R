# =============================================================================
# Program:      02_create_visualizations.R
# Purpose:      Create AE visualizations from the ADAE dataset:
#                 Plot 1: AE severity distribution by treatment arm
#                 Plot 2: Top 10 most frequent AEs with 95% Clopper-Pearson CI
# Input:        pharmaverseadam::adae
# Output:       question_3_tlg/plot1_ae_severity_by_treatment.png
#               question_3_tlg/plot2_top10_ae_frequency.png
# =============================================================================

library(dplyr)
library(ggplot2)
library(forcats)
library(binom)
library(pharmaverseadam)

adae <- pharmaverseadam::adae

# ----------------------------------------------------------------------------
# Plot 1: AE severity distribution by treatment
#   Uses all AE records (not restricted to treatment-emergent) to show the
#   overall distribution of AESEV (MILD/MODERATE/SEVERE) per treatment arm.
# ----------------------------------------------------------------------------
plot1_data <- adae %>%
  mutate(
    AESEV = factor(AESEV, levels = c("MILD", "MODERATE", "SEVERE")),
    ACTARM = factor(
      ACTARM,
      levels = c("Placebo", "Xanomeline Low Dose", "Xanomeline High Dose")
    )
  )

plot1 <- ggplot(plot1_data, aes(x = ACTARM, fill = AESEV)) +
  geom_bar() +
  labs(
    title = "AE severity distribution by treatment",
    x = "Treatment Arm",
    y = "Count of AEs",
    fill = "Severity/Intensity"
  ) +
  theme_minimal()

ggsave(
  filename = file.path("question_3_tlg", "plot1_ae_severity_by_treatment.png"),
  plot = plot1, width = 7, height = 5, dpi = 300
)

# ----------------------------------------------------------------------------
# Plot 2: Top 10 most frequent AEs (with 95% CI for incidence rates)
#   Incidence rate = (number of unique subjects reporting the AETERM) /
#   (number of unique subjects with at least one AE, N = 225).
#   95% CI computed using the exact (Clopper-Pearson) method.
# ----------------------------------------------------------------------------
n_subjects <- n_distinct(adae$USUBJID)

ae_counts <- adae %>%
  distinct(USUBJID, AETERM) %>%
  count(AETERM, name = "n_subj") %>%
  arrange(desc(n_subj)) %>%
  slice_head(n = 10)

ae_ci <- binom.confint(x = ae_counts$n_subj, n = n_subjects, methods = "exact")

ae_incidence <- ae_counts %>%
  mutate(mean = ae_ci$mean, lower = ae_ci$lower, upper = ae_ci$upper)

plot2 <- ggplot(
  ae_incidence,
  aes(x = mean, y = fct_reorder(AETERM, mean))
) +
  geom_pointrange(aes(xmin = lower, xmax = upper)) +
  scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(
    title = "Top 10 Most Frequent Adverse Events",
    subtitle = paste0("n = ", n_subjects, " subjects; 95% Clopper-Pearson CIs"),
    x = "Percentage of Patients (%)",
    y = NULL
  ) +
  theme_minimal()

ggsave(
  filename = file.path("question_3_tlg", "plot2_top10_ae_frequency.png"),
  plot = plot2, width = 7, height = 5, dpi = 300
)

# ----------------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------------
stopifnot(file.exists(file.path("question_3_tlg", "plot1_ae_severity_by_treatment.png")))
stopifnot(file.exists(file.path("question_3_tlg", "plot2_top10_ae_frequency.png")))
stopifnot(nrow(ae_incidence) == 10)

cat("Plot 1 saved: plot1_ae_severity_by_treatment.png\n")
cat("Plot 2 saved: plot2_top10_ae_frequency.png\n")
cat("\nTop 10 AEs by subject incidence:\n")
print(ae_incidence)
