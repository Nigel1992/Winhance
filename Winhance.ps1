# Winhance - Windows Enhancement Utility
# https://github.com/memstechtips/Winhance

using namespace System.Windows.Media
using namespace WinhanceExtensions
using namespace System.Windows.Forms
using namespace System.Drawing
using namespace System.Windows.Automation
using namespace System.Collections
using namespace System.Collections.Generic

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Update the SystemParametersInfo declaration to include all required parameters (for Wallpaper Functions)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Wallpaper {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(
        uint uAction,
        uint uParam,
        string lpvParam,
        uint fuWinIni
    );

    public const uint SPI_SETDESKWALLPAPER = 0x0014;
    public const uint SPIF_UPDATEINIFILE = 0x01;
    public const uint SPIF_SENDCHANGE = 0x02;
}
"@

# Hide the console window as events are logged and shown in the GUI status text
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[Console.Window]::ShowWindow($consolePtr, 0) | Out-Null

# Check if running as administrator
If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Try {
        Start-Process PowerShell.exe -ArgumentList ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath) -Verb RunAs
        Exit
    }
    Catch {
        [System.Windows.MessageBox]::Show("Failed to run as Administrator. Please rerun with elevated privileges.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        Exit
    }
}

# Customize Screen Functions
# =================================

function Set-DarkMode {
    param(
        [bool]$EnableDarkMode,
        [bool]$ChangeWallpaper = $false
    )
    
    try {
        # Apply theme settings
        $settings = $SCRIPT:RegSettings.Personalization |
        Where-Object { $_.Name -in @('AppsUseLightTheme', 'SystemUsesLightTheme') }

        foreach ($setting in $settings) {
            $value = if ($EnableDarkMode) { 
                $setting.RecommendedValue 
            }
            else { 
                $setting.DefaultValue
            }
            
            [RegistryHelper]::ApplyValue($setting, $value)
        }

        # Update transparency setting
        $transparencySetting = $SCRIPT:RegSettings.Personalization |
        Where-Object { $_.Name -eq 'EnableTransparency' } |
        Select-Object -First 1
        
        if ($transparencySetting) {
            [RegistryHelper]::ApplyValue(
                $transparencySetting,
                $transparencySetting.RecommendedValue
            )
        }

        # Handle wallpaper change if requested
        if ($ChangeWallpaper) {
            $windowsVersion = Get-WindowsVersion
            
            try {
                if ($windowsVersion -ge 22000) {
                    # Windows 11
                    $basePath = "$env:SystemRoot\Web\Wallpaper\Windows"
                    if ($EnableDarkMode) {
                        $wallpaperPath = Join-Path $basePath "img19.jpg"
                    }
                    else {
                        $wallpaperPath = Join-Path $basePath "img0.jpg"
                    }
                }
                else {
                    # Windows 10
                    $wallpaperPath = "$env:SystemRoot\Web\4K\Wallpaper\Windows\img0_3840x2160.jpg"
                }

                # Verify path exists before trying to set it
                if (Test-Path $wallpaperPath) {
                    Set-Wallpaper -wallpaperPath $wallpaperPath
                }
                else {
                    Write-Log "Default wallpaper not found at: $wallpaperPath" -Severity Warning
                    Show-MessageBox -Message "Could not find the default wallpaper file." -Icon Warning -Buttons OK
                }
            }
            catch {
                Write-Log "Failed to set wallpaper: $_" -Severity Error
                Show-MessageBox -Message "Failed to change wallpaper: $($_.Exception.Message)" -Icon Error -Buttons OK
            }
        }

        Update-WinGUI
        Write-Log "Dark Mode $(if ($EnableDarkMode) {'enabled'} else {'disabled'})"
        Write-Status -Message "Theme Changed Successfully" -TargetScreen CustomizeScreen
    }
    catch {
        Write-Log "Theme update failed: $_"
        throw
    }
}

# Clean Windows 10 Start Menu
function Reset-Windows10StartMenu {
    
    Write-Status "Cleaning Windows 10 Start Menu..." -TargetScreen CustomizeScreen
    # CLEAN START MENU W10
    # delete startmenulayout.xml
    Remove-Item -Recurse -Force "$env:SystemDrive\Windows\StartMenuLayout.xml" -ErrorAction SilentlyContinue | Out-Null
    # create startmenulayout.xml
    $MultilineComment = @"
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
    <LayoutOptions StartTileGroupCellWidth="6" />
    <DefaultLayoutOverride>
        <StartLayoutCollection>
            <defaultlayout:StartLayout GroupCellWidth="6" />
        </StartLayoutCollection>
    </DefaultLayoutOverride>
</LayoutModificationTemplate>
"@
    Set-Content -Path "C:\Windows\StartMenuLayout.xml" -Value $MultilineComment -Force -Encoding ASCII
    # assign startmenulayout.xml registry
    $layoutFile = "C:\Windows\StartMenuLayout.xml"
    $regAliases = @("HKLM", "HKCU")
    foreach ($regAlias in $regAliases) {
        $basePath = $regAlias + ":\SOFTWARE\Policies\Microsoft\Windows"
        $keyPath = $basePath + "\Explorer"
        IF (!(Test-Path -Path $keyPath)) {
            New-Item -Path $basePath -Name "Explorer" | Out-Null
        }
        Set-ItemProperty -Path $keyPath -Name "LockedStartLayout" -Value 1 | Out-Null
        Set-ItemProperty -Path $keyPath -Name "StartLayoutFile" -Value $layoutFile | Out-Null
    }
    # restart explorer
    Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue | Out-Null
    Timeout /T 5 | Out-Null
    # disable lockedstartlayout registry
    foreach ($regAlias in $regAliases) {
        $basePath = $regAlias + ":\SOFTWARE\Policies\Microsoft\Windows"
        $keyPath = $basePath + "\Explorer"
        Set-ItemProperty -Path $keyPath -Name "LockedStartLayout" -Value 0
    }
    # restart explorer
    Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue | Out-Null
    # delete startmenulayout.xml
    Remove-Item -Recurse -Force "$env:SystemDrive\Windows\StartMenuLayout.xml" -ErrorAction SilentlyContinue | Out-Null

}

# Clean Windows 11 Start Menu
# Source: https://raw.githubusercontent.com/FR33THYFR33THY/Ultimate-Windows-Optimization-Guide/refs/heads/main/6%20Windows/1%20Start%20Menu%20Taskbar.ps1

function Reset-Windows11StartMenu {
    [CmdletBinding()]
    param()
    
    try {

        Write-Status "Cleaning Windows 11 Start Menu..." -TargetScreen CustomizeScreen
        # Suppress progress output
        $progressPreference = 'SilentlyContinue'
        
        # Clean up existing start2.bin if it exists
        Remove-Item -Recurse -Force "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin" -ErrorAction SilentlyContinue
        
        # Base64 encoded certificate content that represents clean start menu layout
        
        $certContent = "-----BEGIN CERTIFICATE-----
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
TSz1QZdkum5Y3uC7wc7paXh1rm11nwluCC7jiA==
-----END CERTIFICATE-----"
        
        # Create temp file with cert content
        New-Item "$env:TEMP\start2.txt" -Value $certContent -Force | Out-Null
        
        # Decode the cert content to binary
        certutil.exe -decode "$env:TEMP\start2.txt" "$env:TEMP\start2.bin" >$null
        
        # Copy the decoded binary to the Start Menu location
        Copy-Item "$env:TEMP\start2.bin" -Destination "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState" -Force | Out-Null
        
        # Clean up temp files
        Remove-Item "$env:TEMP\start2.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\start2.bin" -Force -ErrorAction SilentlyContinue

        # Sets more pins layout (less recommended)
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Set-ItemProperty -Path $regPath -Name "Start_Layout" -Value 1 -Type DWord -Force

        # Refresh Windows GUI
        Update-WinGUI
        
        return $true
    }
    catch {
        Write-Log "Failed to reset Windows 11 Start Menu - $($_.Exception.Message)" -Severity 'ERROR'
        return $false
    }
}

# NOTE
# Taskbar, Explorer, Notifications and Sound are handled by the Invoke-Settings function.

#region 5. GUI Definition
# ====================================================================================================
# GUI Definition
# XAML definition and window creation for the application interface
# ====================================================================================================

# Main Window
$xaml = @'
<Window
	xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
	xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
	xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
	xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
    Title="Winhance"
    Width="1280"
    Height="720"
    Background="Transparent"
    WindowStartupLocation="CenterScreen"
    WindowStyle="None"
    AllowsTransparency="True"
    ResizeMode="CanResize"
    mc:Ignorable="d">
    <!--  WindowChrome for rounded corners  -->
    <WindowChrome.WindowChrome>
        <WindowChrome 
            CaptionHeight="32"
            CornerRadius="10"
            GlassFrameThickness="-1"
            NonClientFrameEdges="None"
            UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
        <!-- Theme Color Resources -->
        <SolidColorBrush x:Key="PrimaryTextColor" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="HelpIconForeground" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="TooltipBackground" Color="#2B2D30"/>
        <SolidColorBrush x:Key="TooltipForeground" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="TooltipBorderBrush" Color="#FFDE00"/>
        <SolidColorBrush x:Key="CheckBoxForeground" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="CheckBoxFillColor" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="CheckBoxBorderBrush" Color="#FFDE00"/>
        <SolidColorBrush x:Key="ContentSectionBorderBrush" Color="#1F2022"/>
        <SolidColorBrush x:Key="MainContainerBorderBrush" Color="#2B2D30"/>
        <SolidColorBrush x:Key="PrimaryButtonForeground" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="ButtonHoverBackground" Color="#FFDE00"/>
        <SolidColorBrush x:Key="ButtonHoverForeground" Color="#202124"/>
        <SolidColorBrush x:Key="ButtonBorderBrush" Color="#FFDE00"/>
        <SolidColorBrush x:Key="ButtonHoverTextColor" Color="#202124"/>
        <SolidColorBrush x:Key="ButtonDisabledForeground" Color="#99A3A4"/>
        <SolidColorBrush x:Key="ButtonDisabledBorderBrush" Color="#2B2D30"/>
        <SolidColorBrush x:Key="ButtonDisabledHoverBackground" Color="#2B2D30"/>
        <SolidColorBrush x:Key="ButtonDisabledHoverForeground" Color="#99A3A4"/>
        <SolidColorBrush x:Key="NavigationButtonBackground" Color="#1F2022"/>
        <SolidColorBrush x:Key="NavigationButtonForeground" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="SliderTrackBackground" Color="#2B2D30"/>
        <SolidColorBrush x:Key="SliderAccentColor" Color="#FFDE00"/>
        <SolidColorBrush x:Key="TickBarForeground" Color="#FFFFFF"/>
        <!--  Button Style for Primary Buttons  -->
        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Foreground" Value="{DynamicResource PrimaryButtonForeground}" />
            <Setter Property="BorderBrush" Value="{DynamicResource ButtonBorderBrush}" />
            <Setter Property="FontFamily" Value="Futura" />
            <Setter Property="FontSize" Value="16" />
            <Setter Property="Width" Value="80" />
            <Setter Property="Height" Value="30" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Padding" Value="15,15" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="2"
                    CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <!--  Hover State for Enabled Button  -->
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBorderBrush}" />
                    <Setter Property="Foreground" Value="{DynamicResource ButtonHoverTextColor}" />
                    <Setter Property="BorderBrush" Value="{DynamicResource ButtonBorderBrush}" />
                </Trigger>
                <!--  Disabled State  -->
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="Transparent" />
                    <Setter Property="Foreground" Value="{DynamicResource ButtonDisabledForeground}" />
                    <Setter Property="BorderBrush" Value="{DynamicResource ButtonDisabledBorderBrush}" />
                    <Setter Property="Cursor" Value="Arrow" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="NavigationButtonStyle" TargetType="Button">
            <Setter Property="Width" Value="70" />
            <Setter Property="Height" Value="70" />
            <Setter Property="Background" Value="{DynamicResource NavigationButtonBackground}" />
            <Setter Property="Foreground" Value="{DynamicResource NavigationButtonForeground}" />
            <Setter Property="FontFamily" Value="Segoe UI Emoji" />
            <!-- Default font family -->
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border
                    x:Name="border"
                    Background="{TemplateBinding Background}"
                    BorderThickness="0"
                    CornerRadius="10">
                            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                                <!-- Icon -->
                                <TextBlock
                            x:Name="icon"
                            Text="{TemplateBinding Tag}"
                            FontFamily="{TemplateBinding FontFamily}"
                            FontSize="24"
                            HorizontalAlignment="Center"
                            Margin="0,5,0,8"
                            Foreground="{TemplateBinding Foreground}" />
                                <!-- Text -->
                                <TextBlock
                            x:Name="text"
                            Text="{TemplateBinding Content}"
                            FontFamily="Helvetica Neue"
                            FontSize="10"
                            HorizontalAlignment="Center"
                            TextWrapping="Wrap"
                            TextAlignment="Center"
                            Foreground="{TemplateBinding Foreground}" />
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <!-- Your existing triggers -->
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <DropShadowEffect x:Key="ShadowEffect" ShadowDepth="5" BlurRadius="10" Color="Black" />
        <DropShadowEffect x:Key="LightShadowEffect" ShadowDepth="5" BlurRadius="10" Color="Black" Opacity="0.5" />
        <!-- Tooltip Style -->
        <Style x:Key="CustomTooltipStyle" TargetType="ToolTip">
            <Setter Property="Background" Value="{DynamicResource TooltipBackground}" />
            <Setter Property="Foreground" Value="{DynamicResource TooltipForeground}" />
            <Setter Property="FontFamily" Value="Segoe UI" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Padding" Value="10" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="BorderBrush" Value="{DynamicResource TooltipBorderBrush}" />
            <Setter Property="MaxWidth" Value="400" />
            <Setter Property="HorizontalContentAlignment" Value="Left" />
        </Style>
        <!-- Help Icon Style -->
        <Style x:Key="HelpIconStyle" TargetType="TextBlock">
            <Setter Property="Text" Value="&#xE946;" />
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets" />
            <Setter Property="FontSize" Value="16" />
            <Setter Property="FontWeight" Value="Normal" />
            <Setter Property="Foreground" Value="{DynamicResource HelpIconForeground}" />
            <Setter Property="VerticalAlignment" Value="Center" />
        </Style>
        <!-- Slider Thumb Style (Pill/Vertical Line) -->
        <Style x:Key="SliderThumbStyle" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Rectangle 
                    Stroke="{DynamicResource SliderAccentColor}"
                    StrokeThickness="2"
                    Fill="{DynamicResource SliderAccentColor}"
                    Width="12"       
                    Height="28"                          
                    RadiusX="2"
                    RadiusY="2">
                            <Rectangle.RenderTransform>
                                <TranslateTransform Y="-1"/>
                            </Rectangle.RenderTransform>
                        </Rectangle>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Slider Track Style -->
        <Style x:Key="SliderRepeatButtonStyle" TargetType="RepeatButton">
            <Setter Property="Background" Value="#404040"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RepeatButton">
                        <Border 
                    Background="{TemplateBinding Background}"
                    IsHitTestVisible="True">
                            <Border.Style>
                                <Style TargetType="Border">
                                    <!-- Default State (Slider Disabled or Value = Minimum) -->
                                    <Setter Property="Height" Value="4"/>
                                    <Setter Property="CornerRadius" Value="2"/>

                                    <!-- Enabled State (Slider Enabled and Value = Maximum) -->
                                    <Style.Triggers>
                                        <!-- Trigger for Slider Enabled -->
                                        <DataTrigger Binding="{Binding IsEnabled, RelativeSource={RelativeSource AncestorType=Slider}}" Value="True">
                                            <Setter Property="Height" Value="14"/>
                                        </DataTrigger>

                                        <!-- Trigger for Slider Value = Maximum (Right) -->
                                        <DataTrigger Binding="{Binding Value, RelativeSource={RelativeSource AncestorType=Slider}}" Value="1">
                                            <Setter Property="Height" Value="14"/>
                                        </DataTrigger>

                                        <!-- Trigger for Slider Value = Minimum (Left) -->
                                        <DataTrigger Binding="{Binding Value, RelativeSource={RelativeSource AncestorType=Slider}}" Value="0">
                                            <Setter Property="Height" Value="8"/>
                                        </DataTrigger>
                                    </Style.Triggers>
                                </Style>
                            </Border.Style>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSliderStyle" TargetType="Slider">
            <Setter Property="Foreground" Value="{DynamicResource SliderAccentColor}"/>
            <Setter Property="Background" Value="#404040"/>
            <Setter Property="Minimum" Value="0"/>
            <Setter Property="Maximum" Value="1"/>
            <Setter Property="TickFrequency" Value="1"/>
            <Setter Property="IsSnapToTickEnabled" Value="True"/>
            <Setter Property="Width" Value="80"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Slider">
                        <Grid>
                            <Track x:Name="PART_Track">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Style="{StaticResource SliderRepeatButtonStyle}" Command="Slider.DecreaseLarge"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource SliderThumbStyle}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Style="{StaticResource SliderRepeatButtonStyle}" Command="Slider.IncreaseLarge"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="UACSliderRepeatButtonStyle" TargetType="RepeatButton">
            <Setter Property="Background" Value="#404040"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RepeatButton">
                        <Border 
                    Background="{TemplateBinding Background}"
                    IsHitTestVisible="True">
                            <Border.Style>
                                <Style TargetType="Border">
                                    <!-- Default State -->
                                    <Setter Property="Height" Value="4"/>
                                    <Setter Property="CornerRadius" Value="2"/>
                                </Style>
                            </Border.Style>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="UACSliderStyle" TargetType="Slider">
            <Setter Property="Foreground" Value="{DynamicResource SliderAccentColor}"/>
            <Setter Property="Background" Value="#404040"/>
            <Setter Property="Minimum" Value="0"/>
            <Setter Property="Maximum" Value="2"/>
            <Setter Property="TickFrequency" Value="1"/>
            <Setter Property="IsSnapToTickEnabled" Value="True"/>
            <Setter Property="Width" Value="200"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Slider">
                        <Grid>
                            <Track x:Name="PART_Track">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Style="{StaticResource UACSliderRepeatButtonStyle}" Command="Slider.DecreaseLarge"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource SliderThumbStyle}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Style="{StaticResource UACSliderRepeatButtonStyle}" Command="Slider.IncreaseLarge"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                            <TickBar 
                        Fill="{DynamicResource TickBarForeground}"
                        Placement="Top"
                        Height="4"
                        Margin="0,-15,0,0"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Checkbox Style -->
        <Style x:Key="CustomCheckBoxStyle" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource CheckBoxForeground}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="{DynamicResource CheckBoxBorderBrush}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border x:Name="CheckBoxBorder" 
                        Width="17" Height="17" 
                        BorderThickness="1.5"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        Background="{TemplateBinding Background}"
                        CornerRadius="3">
                                <Border x:Name="InnerFill"
                            Margin="3"
                            Background="Transparent"
                            CornerRadius="1"/>
                            </Border>
                            <ContentPresenter Grid.Column="1"
                        Margin="10,0,0,0"
                        VerticalAlignment="Center"
                        HorizontalAlignment="Left"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerFill" Property="Background" Value="{DynamicResource CheckBoxFillColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CheckBoxBorder" Property="BorderBrush" Value="{DynamicResource CheckBoxBorderBrush}"/>
                                <Setter TargetName="CheckBoxBorder" Property="Opacity" Value="0.8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <!--  Outer Border for rounded corners and window appearance  -->
    <Border
<#
        Padding="10"
        Background="#202020"
        CornerRadius="10">
        <Grid Margin="-10,-10,-10,-10">
            <!--  Title in Top-Left Corner  -->
            <DockPanel
                Margin="10,5,0,0"
                HorizontalAlignment="Left"
                VerticalAlignment="Top">
                <!--  Icon  -->
                <TextBlock
                    Margin="0,-2,5,0"
                    FontFamily="Segoe UI Emoji"
                    FontSize="18"
                    Foreground="{DynamicResource PrimaryTextColor}"
                    Text="&#x1F680;" />
                <!--  Program Name  -->
                <TextBlock
                    FontFamily="Helvetica Neue"
                    FontSize="18"
                    FontWeight="Light"
                    Foreground="{DynamicResource PrimaryTextColor}">
					<Run Text="Winhance "/>
					<Run
                        FontSize="12"
                        FontStyle="Italic"
                        Foreground="Gray"
                        Text="by Memory" />
                </TextBlock>
            </DockPanel>
            <!-- Buttons in Top-Right Corner  -->
            <DockPanel HorizontalAlignment="Right" VerticalAlignment="Top">
                <Button
x:Name="ThemeToggleButton"
Width="28"
Height="28"
Background="Transparent"
Content="&#xE793;"
FontFamily="Segoe MDL2 Assets"
FontSize="12"
Foreground="{DynamicResource PrimaryTextColor}"
Margin="0,0,5,0">
                    <WindowChrome.IsHitTestVisibleInChrome>True</WindowChrome.IsHitTestVisibleInChrome>
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border
            x:Name="border"
            Background="Transparent"
            BorderBrush="Transparent"
            BorderThickness="1">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="border" Property="Background" Value="#404040" />
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button
    x:Name="MinimizeButton"
    Width="28"
    Height="28"
    Background="Transparent"
    Content="&#xE949;"
    FontFamily="Segoe MDL2 Assets"
    FontSize="12"
    Foreground="{DynamicResource PrimaryTextColor}"
    Margin="0,0,5,0">
                    <WindowChrome.IsHitTestVisibleInChrome>True</WindowChrome.IsHitTestVisibleInChrome>
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border
                x:Name="border"
                Background="Transparent"
                BorderBrush="Transparent"
                BorderThickness="1">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="border" Property="Background" Value="#404040" />
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button
    x:Name="MaximizeButton"
    Width="28"
    Height="28"
    Background="Transparent"
    Content="&#xE739;"
    FontFamily="Segoe MDL2 Assets"
    FontSize="12"
    Foreground="{DynamicResource PrimaryTextColor}"
    Margin="0,0,5,0">
                    <WindowChrome.IsHitTestVisibleInChrome>True</WindowChrome.IsHitTestVisibleInChrome>
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border
                x:Name="border"
                Background="Transparent"
                BorderBrush="Transparent"
                BorderThickness="1">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="border" Property="Background" Value="#404040" />
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button
                    x:Name="CloseButton"
                    Width="28"
                    Height="28"
                    Background="Transparent"
                    Content="&#xE10A;"
                    FontFamily="Segoe MDL2 Assets"
                    FontSize="12"
                    FontWeight="ExtraLight"
                    Foreground="{DynamicResource PrimaryTextColor}">
                    <WindowChrome.IsHitTestVisibleInChrome>True</WindowChrome.IsHitTestVisibleInChrome>
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border
                                x:Name="border"
                                Background="Transparent"
                                BorderBrush="Transparent"
                                BorderThickness="1"
                                CornerRadius="0,10,0,0">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                            </Border>
                            <ControlTemplate.Triggers>
                                <!--  Change background and border on hover  -->
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="border" Property="Background" Value="Red" />
                                    <Setter TargetName="border" Property="BorderBrush" Value="Red" />
                                    <!--  Visible border on hover  -->
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="border" Property="Background" Value="DarkRed" />
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </DockPanel>
            <StackPanel x:Name="NavigationPanel" 
          Orientation="Vertical" 
          HorizontalAlignment="Left" 
          VerticalAlignment="Top" 
          Margin="10,56,0,0">
                <!-- Top Navigation Buttons -->
                <Button x:Name="SoftwareAppsNavButton" 
            Style="{DynamicResource NavigationButtonStyle}" 
            Tag="&#x1F4BF;"
            Margin="0,0,0,10"
            Content="Software &amp; Apps"/>

                <Button x:Name="OptimizeNavButton"
            Style="{DynamicResource NavigationButtonStyle}" 
            Tag="&#x1F680;"
            Margin="0,0,0,10"
            Content="Optimize"/>

                <Button x:Name="CustomizeNavButton"
            Style="{DynamicResource NavigationButtonStyle}" 
            Tag="&#x1F3A8;"
            Margin="0,0,0,10"
            Content="Customize"/>

                <!-- Fixed spacer -->
                <Rectangle Height="235" Fill="Transparent"/>

                <!-- About Button -->
                <Button x:Name="AboutNavButton"
            Style="{DynamicResource NavigationButtonStyle}" 
            Tag="&#xE946;" 
            FontFamily="Segoe MDL2 Assets"
            Margin="0,0,0,10"
            Content="About" />
            </StackPanel>
            <!-- Software and Apps Screen -->
            <StackPanel x:Name="SoftAppsScreen" Width="943" Height="550" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="93,56,0,0" Visibility="Collapsed">
                <!-- Header -->
                <DockPanel HorizontalAlignment="Left" VerticalAlignment="Center">
                    <TextBlock Width="80" Height="70" Margin="0,0,0,0" DockPanel.Dock="Left" FontFamily="Segoe UI Emoji" FontSize="60" Foreground="{DynamicResource PrimaryTextColor}" Text="&#x1F4BF;"  LineHeight="70" LineStackingStrategy="BlockLineHeight" />
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Height="35" VerticalAlignment="Top" FontFamily="Helvetica Neue" FontSize="32" FontWeight="Bold" Foreground="{DynamicResource PrimaryTextColor}" Text="Software &amp; Apps" />
                        <TextBlock x:Name="SoftAppsStatusText" Height="22" Margin="0,5,0,0" VerticalAlignment="Bottom" FontFamily="Helvetica Neue" FontSize="14" Foreground="DarkGray" Text="Manage software installation and removal" />
                    </StackPanel>
                </DockPanel>

                <!-- Main Content -->
                <Border x:Name="SoftAppsMainContentBorder" Margin="0,5,0,0" Background="{DynamicResource MainContainerBorderBrush}" CornerRadius="10" Height="470">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Margin="10">
                            <!-- Install Software Section -->
                            <StackPanel>
                                <Border x:Name="InstallSoftwareHeader" Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="0,5,0,5" Effect="{StaticResource ShadowEffect}">
                                    <DockPanel VerticalAlignment="Center" HorizontalAlignment="Stretch">
                                        <TextBlock Text="Install Software" HorizontalAlignment="Left" VerticalAlignment="Center" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource PrimaryTextColor}" Padding="10" DockPanel.Dock="Left" />
                                        <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="16" Foreground="{DynamicResource PrimaryTextColor}" Padding="10" DockPanel.Dock="Right" />
                                    </DockPanel>
                                </Border>
                                <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,0,5,5" Effect="{StaticResource LightShadowEffect}">
                                    <StackPanel x:Name="InstallSoftwareContent" Margin="0,10,0,10" Visibility="Collapsed">
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Microsoft Store" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallStore" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="UniGetUI" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallUniGetUI" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Thorium Browser" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallThorium" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Firefox" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallFirefox" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Chrome" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallChrome" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Brave" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallBrave" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Microsoft Edge" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallEdge" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Microsoft Edge WebView" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallEdgeWebView" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Microsoft OneDrive" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallOneDrive" />
                                        </Grid>
                                        <Grid Margin="10,5">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Xbox App for Windows" VerticalAlignment="Center" Foreground="{DynamicResource PrimaryTextColor}" FontSize="14" Margin="10,0,0,0" Grid.Column="0" />
                                            <Button Style="{DynamicResource PrimaryButtonStyle}" Content="Install" Width="80" Height="30" HorizontalAlignment="Right" Grid.Column="1" x:Name="InstallXbox" />
                                        </Grid>
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                            <!-- Remove Windows Apps Section -->
                            <StackPanel>
                                <Border x:Name="RemoveAppsHeader" Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="0,5,0,5" Effect="{StaticResource ShadowEffect}">
                                    <DockPanel VerticalAlignment="Center" HorizontalAlignment="Stretch">
                                        <TextBlock Text="Remove Windows Apps" HorizontalAlignment="Left" VerticalAlignment="Center" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource PrimaryTextColor}" Padding="10" DockPanel.Dock="Left" />
                                        <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="16" Foreground="{DynamicResource PrimaryTextColor}" Padding="10" DockPanel.Dock="Right" />
                                    </DockPanel>
                                </Border>
                                <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,0,5,5" Effect="{StaticResource LightShadowEffect}">
                                    <StackPanel x:Name="RemoveAppsContent" Margin="0,10,0,10">
                                        <!-- Add a dedicated container for the dynamic checkboxes -->
                                        <StackPanel x:Name="chkPanel" Margin="0,0,0,10"></StackPanel>
                                    </StackPanel>
                                </Border>
                            </StackPanel>

                        </StackPanel>
                    </ScrollViewer>
                </Border>
            </StackPanel>
            <!-- Optimize Screen -->
            <StackPanel x:Name="OptimizeScreen" Width="943" Height="550" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="93,56,0,0" Visibility="Collapsed">
                <!-- Header -->
                <DockPanel HorizontalAlignment="Left" VerticalAlignment="Center">
                    <TextBlock Width="80" Height="70" Margin="0,0,0,0" DockPanel.Dock="Left" FontFamily="Segoe UI Emoji" FontSize="60" Foreground="{DynamicResource PrimaryTextColor}" Text="&#x1F680;"  LineHeight="70" LineStackingStrategy="BlockLineHeight" />
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Height="35" VerticalAlignment="Top" FontFamily="Helvetica Neue" FontSize="32" FontWeight="Bold" Foreground="{DynamicResource PrimaryTextColor}" Text="Optimizations" />
                        <DockPanel LastChildFill="False" Width="861">
                            <TextBlock x:Name="OptimizeStatusText" Height="22" DockPanel.Dock="Left" VerticalAlignment="Bottom" FontFamily="Helvetica Neue" FontSize="14" Foreground="DarkGray" Text="Optimize your system settings and performance" />
                            <Button x:Name="OptimizeDefaultsButton" DockPanel.Dock="Right" Style="{DynamicResource PrimaryButtonStyle}" Content="Defaults" Width="80" Height="30" Margin="0,0,5,0"/>
                            <Button x:Name="OptimizeApplyButton" DockPanel.Dock="Right" Style="{DynamicResource PrimaryButtonStyle}" Content="Apply" Width="80" Height="30" Margin="0,0,10,0"/>
                        </DockPanel>
                    </StackPanel>
                </DockPanel>
                <!-- Main Content -->
                <Border x:Name="OptimizeMainContentBorder" Margin="0,5,0,0" Background="{DynamicResource MainContainerBorderBrush}" CornerRadius="10" Height="470">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Margin="10">
                            <Border x:Name="WindowsSecurityHeaderBorder" Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="0,5,0,5" Effect="{StaticResource ShadowEffect}">
                                <DockPanel VerticalAlignment="Center" HorizontalAlignment="Stretch">
                                    <TextBlock Text="Windows Security Settings" HorizontalAlignment="Left" VerticalAlignment="Center" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource PrimaryTextColor}" Padding="10" DockPanel.Dock="Left" />
                                    <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="16" Foreground="{DynamicResource PrimaryTextColor}" Padding="10" DockPanel.Dock="Right" />
                                </DockPanel>
                            </Border>

                            <!-- Windows Security Section -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,0,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel x:Name="WindowsSecurityContent" Margin="0,10,0,10" >
                                    <!-- UAC Notification Level Section -->
                                    <Grid Margin="10,0,0,10">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>

                                        <!-- Left: Title -->
                                        <StackPanel Orientation="Vertical" VerticalAlignment="Top">
                                            <TextBlock 
                                Text="UAC Notification Level (Recommended: Low)" 
                                Foreground="{DynamicResource PrimaryTextColor}"
                                FontSize="14" 
                                Margin="25,20,0,0"/>
                                        </StackPanel>

                                        <!-- Right: Slider -->
                                        <StackPanel Grid.Column="1" Margin="10,0">
                                            <!-- Tick Labels -->
                                            <Grid Margin="0,0,0,5">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Text="Low" Foreground="{DynamicResource PrimaryTextColor}" HorizontalAlignment="Left"/>
                                                <TextBlock Text="Moderate" Foreground="{DynamicResource PrimaryTextColor}" Grid.Column="1" HorizontalAlignment="Center"/>
                                                <TextBlock Text="High" Foreground="{DynamicResource PrimaryTextColor}" Grid.Column="2" HorizontalAlignment="Right"/>
                                            </Grid>

                                            <!-- Slider Control -->
                                            <Slider x:Name="UACSlider" 
                                Style="{DynamicResource UACSliderStyle}"
                                Minimum="0"
                                Maximum="2"
                                TickFrequency="1"/>
                                        </StackPanel>
                                    </Grid>
                                </StackPanel>
                            </Border>

                            <!-- Select All Checkbox -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <CheckBox x:Name="OptimizeSelectAllCheckbox"
Content="Select All"
Style="{DynamicResource CustomCheckBoxStyle}"
FontSize="14"
Margin="27,0,0,0"/>
                                </StackPanel>
                            </Border>
                            <!-- Privacy Settings -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <TextBlock Style="{DynamicResource HelpIconStyle}" Margin="0,0,10,0">
                                        <TextBlock.ToolTip>
                                            <ToolTip Style="{DynamicResource CustomTooltipStyle}">
                                                <TextBlock>
                                   Disables:
<LineBreak />- Activity History &amp; User Activity Tracking
<LineBreak />- Location Services &amp; Maps
<LineBreak />- Telemetry &amp; Diagnostic Data Collection
<LineBreak />- Feedback &amp; Error Reporting
<LineBreak />- Windows Ink Workspace
<LineBreak />- Advertising ID &amp; Personalized Ads
<LineBreak />- Account Info &amp; Notifications
<LineBreak />- Language &amp; Input Data Collection
<LineBreak />- Speech Recognition
<LineBreak />- Inking &amp; Typing Data Collection
<LineBreak />- Remote Assistance
<LineBreak />- Device Metadata Collection
<LineBreak />- Windows Consumer Features
<LineBreak />- Background Apps
<LineBreak />- Cortana
<LineBreak />- WiFi Sense Features
<LineBreak />- Automatic Maintenance
<LineBreak />- Push to Install
<LineBreak />- Ads &amp; Promotional Content
<LineBreak />- Lock Screen Features &amp; Slideshows
<LineBreak />- Automatic Bitlocker Drive Encryption
<LineBreak />- TCG security device activation
<LineBreak />- Automatic restart sign-on
                                                </TextBlock>
                                            </ToolTip>
                                        </TextBlock.ToolTip>
                    </TextBlock>
                                    <CheckBox x:Name="PrivacyCheckBox"
                             Content="Privacy Settings"
                             Style="{DynamicResource CustomCheckBoxStyle}"
                             FontSize="14"/>
                                </StackPanel>
                            </Border>

                            <!-- Gaming Optimizations -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <TextBlock Style="{DynamicResource HelpIconStyle}" Margin="0,0,10,0">
                                        <TextBlock.ToolTip>
                                            <ToolTip Style="{DynamicResource CustomTooltipStyle}">
                                                <TextBlock>
                                 - Enables Game Mode
<LineBreak />- Disables Game Bar &amp; Game DVR
<LineBreak />- Disables opening Xbox Game Bar using a controller
<LineBreak />- Disables variable refresh rate
<LineBreak />- Enables optimizations for windowed games
<LineBreak />- Enables old Nvidia sharpening
<LineBreak />- Improves system responsiveness for multimedia apps
<LineBreak />- Adjusts network for better gaming performance
<LineBreak />- Increases CPU &amp; GPU priority for gaming
<LineBreak />- Sets scheduling category to High for games
<LineBreak />- Enables hardware-accelerated GPU scheduling
<LineBreak />- Adjusts Win32 priority separation for best performance
<LineBreak />- Disables Storage Sense
                                                </TextBlock>
                                            </ToolTip>
                                        </TextBlock.ToolTip>
                    </TextBlock>
                                    <CheckBox x:Name="GamingOptimizationsCheckBox"
                             Content="Gaming Optimizations"
                             Style="{DynamicResource CustomCheckBoxStyle}"
                             FontSize="14"/>
                                </StackPanel>
                            </Border>

                            <!-- Windows Updates -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <TextBlock Style="{DynamicResource HelpIconStyle}" Margin="0,0,10,0">
                                        <TextBlock.ToolTip>
                                            <ToolTip Style="{DynamicResource CustomTooltipStyle}">
                                                <TextBlock>
                                    Disables:
<LineBreak />- Automatic Updates
<LineBreak />- Delays Feature Updates (365 days)
<LineBreak />- Delays Security Updates (7 days)
<LineBreak />- Automatic Upgrade from Win10 to Win11
<LineBreak />- Delivery Optimization
<LineBreak />- Auto updates for Store apps
<LineBreak />- Auto archiving of unused apps
                                                </TextBlock>
                                            </ToolTip>
                                        </TextBlock.ToolTip>
                    </TextBlock>
                                    <CheckBox x:Name="WindowsUpdatesCheckBox"
                             Content="Windows Updates"
                             Style="{DynamicResource CustomCheckBoxStyle}"
                             FontSize="14"/>
                                </StackPanel>
                            </Border>

                            <!-- Power Settings -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <TextBlock Style="{DynamicResource HelpIconStyle}" Margin="0,0,10,0">
                                        <TextBlock.ToolTip>
                                            <ToolTip Style="{DynamicResource CustomTooltipStyle}">
                                                <TextBlock>
                                    - Ultimate Power Plan (Max Performance)
<LineBreak />- Disables Hibernate, Sleep, and Fast Boot
<LineBreak />- Unparks CPU Cores
<LineBreak />- Disables Power Throttling
<LineBreak />- USB Selective Suspend Disabled
<LineBreak />- PCI Express Link State Power Management Off
<LineBreak />- Processor State Always at 100%
<LineBreak />- Display Always On, Brightness at 100%
<LineBreak />- Battery Saver Disabled
<LineBreak />- Critical Battery Actions Disabled
                                                </TextBlock>
                                            </ToolTip>
                                        </TextBlock.ToolTip>
                    </TextBlock>
                                    <CheckBox x:Name="PowerSettingsCheckBox"
                             Content="Power Settings"
                             Style="{DynamicResource CustomCheckBoxStyle}"
                             FontSize="14"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Border>
            </StackPanel>

            <!-- Customize Screen -->
            <StackPanel x:Name="CustomizeScreen" Width="943" Height="550" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="93,56,0,0" >
                <!-- Header -->
                <DockPanel HorizontalAlignment="Left" VerticalAlignment="Center">
                    <TextBlock Width="80" Height="70" Margin="0,0,0,0" DockPanel.Dock="Left" FontFamily="Segoe UI Emoji" FontSize="60" Foreground="{DynamicResource PrimaryTextColor}" Text="&#x1F3A8;"  LineHeight="70" LineStackingStrategy="BlockLineHeight" />
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Height="35" VerticalAlignment="Top" FontFamily="Helvetica Neue" FontSize="32" FontWeight="Bold" Foreground="{DynamicResource PrimaryTextColor}" Text="Customize" />
                        <DockPanel LastChildFill="False" Width="861">
                            <TextBlock x:Name="CustomizeStatusText" Height="22" DockPanel.Dock="Left" VerticalAlignment="Bottom" FontFamily="Helvetica Neue" FontSize="14" Foreground="DarkGray" Text="Customize your system's appearance and behavior" />
                            <Button x:Name="CustomizeDefaultsButton" DockPanel.Dock="Right" Style="{DynamicResource PrimaryButtonStyle}" Content="Defaults" Width="80" Height="30" Margin="0,0,5,0"/>
                            <Button x:Name="CustomizeApplyButton" DockPanel.Dock="Right" Style="{DynamicResource PrimaryButtonStyle}" Content="Apply" Width="80" Height="30" Margin="0,0,10,0"/>
                        </DockPanel>
                    </StackPanel>
                </DockPanel>

                <!-- Main Content -->
                <Border x:Name="CustomizeMainContentBorder" Margin="0,5,0,0" Background="{DynamicResource MainContainerBorderBrush}" CornerRadius="10" Height="470" >
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Margin="10">
                            <!-- Theme Settings -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Margin="10">
                                    <!-- Dark Mode -->
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*" />
                                            <ColumnDefinition Width="Auto" />
                                        </Grid.ColumnDefinitions>

                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock 
            Text="&#xE793;"
            FontFamily="Segoe MDL2 Assets"
            VerticalAlignment="Center" 
            Foreground="{DynamicResource PrimaryTextColor}" 
            FontSize="20"
            Margin="25,0,0,0" />
                                            <TextBlock 
            Text="Dark Mode" 
            VerticalAlignment="Center" 
            Foreground="{DynamicResource PrimaryTextColor}" 
            FontSize="14" 
            Margin="8,0,0,0" />
                                        </StackPanel>
                                        <Slider x:Name="DarkModeSlider" 
                   Style="{DynamicResource ToggleSliderStyle}" 
                   Grid.Column="1"
                   HorizontalAlignment="Right"/>
                                    </Grid>
                                </StackPanel>
                            </Border>

                            <!-- Select All Checkbox -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <CheckBox x:Name="CustomizeSelectAllCheckbox"
                 Content="Select All"
                 Style="{DynamicResource CustomCheckBoxStyle}"
                 FontSize="14"
                 Margin="27,0,0,0"/>
                                </StackPanel>
                            </Border>
                            <!-- Taskbar Section -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <TextBlock Style="{DynamicResource HelpIconStyle}" Margin="0,0,10,0">
                                        <TextBlock.ToolTip>
                                            <ToolTip Style="{DynamicResource CustomTooltipStyle}">
                                                <TextBlock>
- Hides Windows Chat icon
<LineBreak />- Disables News and Interests feed
<LineBreak />- Hides Meet Now button
<LineBreak />- Hides Task View button
<LineBreak />- Disables system tray auto-hide
<LineBreak />- Clears frequently used programs list
<LineBreak />- Hides Copilot button
<LineBreak />- Left-aligns taskbar icons
                                                </TextBlock>
                                            </ToolTip>
                                        </TextBlock.ToolTip>
                        </TextBlock>
                                    <CheckBox x:Name="TaskbarCheckBox"
                                 Content="Taskbar"
                                 Style="{DynamicResource CustomCheckBoxStyle}"
                                 FontSize="14"/>
                                </StackPanel>
                            </Border>

                            <!-- Start Menu Section -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <TextBlock Style="{DynamicResource HelpIconStyle}" Margin="0,0,10,0">
                                        <TextBlock.ToolTip>
                                            <ToolTip Style="{DynamicResource CustomTooltipStyle}">
                                                <TextBlock>
                                        - Removes all pinned apps
<LineBreak />- Sets "More Pins" layout (less recommended)
                                                </TextBlock>
                                            </ToolTip>
                                        </TextBlock.ToolTip>
                        </TextBlock>
                                    <CheckBox x:Name="StartMenuCheckBox"
                                 Content="Start Menu"
                                 Style="{DynamicResource CustomCheckBoxStyle}"
                                 FontSize="14"/>
                                </StackPanel>
                            </Border>

                            <!-- Explorer Section -->
                            <Border Background="{DynamicResource ContentSectionBorderBrush}" CornerRadius="5" Margin="5,5,5,5" Effect="{StaticResource LightShadowEffect}">
                                <StackPanel Orientation="Horizontal" Margin="10">
                                    <TextBlock Style="{DynamicResource HelpIconStyle}" Margin="0,0,10,0">
                                        <TextBlock.ToolTip>
                                            <ToolTip Style="{DynamicResource CustomTooltipStyle}">
                                                <TextBlock>
                                        - Enables long file paths (32,767 chars)
<LineBreak />- Disables Windows Spotlight wallpaper feature
<LineBreak />- Blocks "Allow my organization to manage my device" pop-up
<LineBreak />- Removes 3D Objects and Home Folder
<LineBreak />- Opens File Explorer to "This PC"
<LineBreak />- Shows file name extensions
<LineBreak />- Disables folder tips and pop-up descriptions
<LineBreak />- Disables preview handlers and status bar
<LineBreak />- Disables sync provider notifications
<LineBreak />- Disables sharing wizard
<LineBreak />- Disables taskbar animations
<LineBreak />- Shows thumbnails instead of icons
<LineBreak />- Disables translucent selection rectangle
<LineBreak />- Disables shadows for icon labels
<LineBreak />- Disables account-related notifications
<LineBreak />- Disables recently opened items in Start and File Explorer
<LineBreak />- Disables recommendations for tips and shortcuts
<LineBreak />- Disables snap assist and window animations
<LineBreak />- Sets Alt+Tab to show open windows only
<LineBreak />- Hides frequent folders in Quick Access
<LineBreak />- Disables files from Office.com in Quick Access
<LineBreak />- Enables full path in title bar
<LineBreak />- Disables enhance pointer precision (mouse fix)
<LineBreak />- Sets appearance options to custom
<LineBreak />- Disables animations and visual effects
<LineBreak />- Enables smooth edges of screen fonts
<LineBreak />- Disables menu show delay
</TextBlock>
</ToolTip>
</TextBlock.ToolTip>
</TextBlock>
<CheckBox x:Name="ExplorerCheckBox"
Content="Explorer"
Style="{DynamicResource CustomCheckBoxStyle}"
FontSize="14"/>
</StackPanel>
</Border>
</StackPanel>
</ScrollViewer>
</Border>
</StackPanel>
</Window>
'@