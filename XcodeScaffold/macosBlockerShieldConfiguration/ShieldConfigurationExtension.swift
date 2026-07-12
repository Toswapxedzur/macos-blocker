import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration(
            title: "Blocked",
            subtitle: "Mac Vault is shielding this app.",
            primaryButton: "Open Mac Vault",
            secondaryButton: "Request Snooze"
        )
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        configuration(
            title: "Category Blocked",
            subtitle: "This category is currently blocked by Mac Vault.",
            primaryButton: "Open Mac Vault",
            secondaryButton: "Request Snooze"
        )
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration(
            title: "Website Blocked",
            subtitle: "This website is currently blocked by Mac Vault.",
            primaryButton: "Open Mac Vault",
            secondaryButton: "Request Snooze"
        )
    }

    private func configuration(
        title: String,
        subtitle: String,
        primaryButton: String,
        secondaryButton: String
    ) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: UIColor.systemIndigo,
            icon: UIImage(systemName: "shield.fill"),
            title: ShieldConfiguration.Label(text: title, color: .white),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: .white.withAlphaComponent(0.86)),
            primaryButtonLabel: ShieldConfiguration.Label(text: primaryButton, color: .systemIndigo),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: ShieldConfiguration.Label(text: secondaryButton, color: .white)
        )
    }
}
