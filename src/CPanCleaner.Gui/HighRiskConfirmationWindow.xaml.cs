using System.Windows;
using System.Windows.Controls;
using CPanCleaner.Gui.Models;

namespace CPanCleaner.Gui;

public partial class HighRiskConfirmationWindow : Window
{
    public HighRiskConfirmationWindow(CleanerFeature feature)
    {
        InitializeComponent();
        FeatureTitleText.Text = feature.Title;
        WarningText.Text = string.IsNullOrWhiteSpace(feature.ApplyWarning) ? feature.Impact : feature.ApplyWarning;
    }

    private void ConfirmationText_OnTextChanged(object sender, TextChangedEventArgs e)
    {
        ConfirmButton.IsEnabled = string.Equals(ConfirmationText.Text.Trim(), "执行", StringComparison.Ordinal);
    }

    private void Confirm_OnClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void Cancel_OnClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
