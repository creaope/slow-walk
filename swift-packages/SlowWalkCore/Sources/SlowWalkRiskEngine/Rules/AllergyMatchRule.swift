import SlowWalkDomain

/// Raises a red reminder when a normalized allergy exactly matches sourced
/// medicine identity or an existing canonical safety label.
///
/// Product names are included because an allergy record may identify a
/// pharmaceutical product rather than only an ingredient. Matching remains an
/// exact set intersection after case and surrounding-whitespace normalization;
/// this rule intentionally performs no substring, fuzzy, or drug-class match.
public struct AllergyMatchRule: MedicationRiskRule {
    public let identifier = "allergy-match"

    public init() {}

    public func evaluate(context: MedicationRiskContext) -> RiskFinding? {
        let allergies = RuleSupport.normalizedSet(context.userProfile.allergies)
        let medicineLabels = RuleSupport.normalizedSet(
            [context.medicine.canonicalName]
                + context.medicine.aliases
                + context.medicine.contraindicationTags
                + context.medicine.activeIngredientIDs
        )
        let matches = allergies.intersection(medicineLabels).sorted()

        guard !matches.isEmpty else {
            return nil
        }

        return RiskFinding(
            level: .red,
            reason: RiskReason(
                code: .allergyMatch,
                message: "The medicine label matches information in the allergy profile.",
                evidence: "Matched normalized labels: \(matches.joined(separator: ", ")).",
                ruleIdentifier: identifier
            ),
            recommendedActions: [
                .doNotTakeUntilMedicineConfirmed,
                .consultHealthcareProfessional,
                .notifyFamilyMember,
            ],
            requiresProfessionalAdvice: true,
            requiresFamilyAttention: true,
            evidenceCompleteness: context.evidenceCompleteness
        )
    }
}
