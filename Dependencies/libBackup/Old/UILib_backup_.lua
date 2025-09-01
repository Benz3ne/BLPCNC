-- UILib v1.0 - Shared UI Components for Mach4 Scripts
-- Provides resizable dialogs, standardized controls, and consistent UI patterns
-- Generated: 2025-08-27

local UILib = {
    VERSION = "1.0.1",
    DialogGeometry = {},
    ResizableDialog = {},
    Controls = {},
    Msg = {},
    Styles = {},
    Validate = {},
    Progress = {},
    Image = {},
    Wizard = {}
}

-- ============================================
-- STYLES - Consistent UI Styling Constants
-- ============================================

-- Color constants
UILib.Styles.Colors = {
    ButtonGreen = wx.wxColour(0, 200, 0),
    ButtonRed = wx.wxColour(200, 0, 0),
    WarningYellow = wx.wxColour(255, 200, 0),
    DisabledGray = wx.wxColour(128, 128, 128),
    InfoBlue = wx.wxColour(0, 100, 200),
    Background = wx.wxColour(240, 240, 240)
}

-- Size constants
UILib.Styles.Sizes = {
    ButtonWidth = 80,
    ButtonHeight = 30,
    DialogPadding = 10,
    LabelWidth = 100,
    InputWidth = 80,
    SpacerSmall = 5,
    SpacerMedium = 10,
    SpacerLarge = 20
}

-- Font constants
UILib.Styles.Fonts = {
    Default = wx.wxFont(9, wx.wxFONTFAMILY_DEFAULT, wx.wxFONTSTYLE_NORMAL, wx.wxFONTWEIGHT_NORMAL),
    Bold = wx.wxFont(9, wx.wxFONTFAMILY_DEFAULT, wx.wxFONTSTYLE_NORMAL, wx.wxFONTWEIGHT_BOLD),
    Large = wx.wxFont(11, wx.wxFONTFAMILY_DEFAULT, wx.wxFONTSTYLE_NORMAL, wx.wxFONTWEIGHT_NORMAL),
    Small = wx.wxFont(8, wx.wxFONTFAMILY_DEFAULT, wx.wxFONTSTYLE_NORMAL, wx.wxFONTWEIGHT_NORMAL),
    Italic = wx.wxFont(9, wx.wxFONTFAMILY_DEFAULT, wx.wxFONTSTYLE_ITALIC, wx.wxFONTWEIGHT_NORMAL)
}

-- ============================================
-- DIALOG GEOMETRY - Save/Restore Window Positions
-- ============================================

-- Get profile path for saving dialog geometry
function UILib.DialogGeometry.GetProfilePath(inst)
    local profileName = mc.mcProfileGetName(inst)
    return mc.mcCntlGetMachDir(inst) .. "\\Profiles\\" .. profileName
end

-- Save dialog geometry to profile
function UILib.DialogGeometry.Save(inst, dialogName, x, y, width, height)
    local section = "DialogGeometry_" .. dialogName
    mc.mcProfileWriteString(inst, section, "X", tostring(x))
    mc.mcProfileWriteString(inst, section, "Y", tostring(y))
    mc.mcProfileWriteString(inst, section, "Width", tostring(width))
    mc.mcProfileWriteString(inst, section, "Height", tostring(height))
    mc.mcProfileFlush(inst)
end

-- Load dialog geometry from profile
function UILib.DialogGeometry.Load(inst, dialogName, defaultW, defaultH)
    local section = "DialogGeometry_" .. dialogName
    
    -- Get screen dimensions for validation
    local sw = wx.wxSystemSettings.GetMetric(wx.wxSYS_SCREEN_X) or 1024
    local sh = wx.wxSystemSettings.GetMetric(wx.wxSYS_SCREEN_Y) or 768
    
    -- Load saved values
    local x = tonumber(mc.mcProfileGetString(inst, section, "X", "-1")) or -1
    local y = tonumber(mc.mcProfileGetString(inst, section, "Y", "-1")) or -1
    local w = tonumber(mc.mcProfileGetString(inst, section, "Width", tostring(defaultW))) or defaultW
    local h = tonumber(mc.mcProfileGetString(inst, section, "Height", tostring(defaultH))) or defaultH
    
    -- Validate and adjust if needed
    if x < 0 or y < 0 or x > sw - 100 or y > sh - 100 then
        -- Center if position is invalid
        x = math.floor((sw - w) / 2)
        y = math.floor((sh - h) / 2)
    end
    
    -- Ensure minimum size
    w = math.max(w, 200)
    h = math.max(h, 150)
    
    -- Ensure dialog fits on screen
    w = math.min(w, sw - 50)
    h = math.min(h, sh - 50)
    
    return x, y, w, h
end

-- ============================================
-- RESIZABLE DIALOG - Create Resizable Dialogs with Saved Geometry
-- ============================================

-- Create a resizable dialog with saved geometry
function UILib.ResizableDialog.Create(parent, title, dialogName, defaultW, defaultH, style)
    local inst = mc.mcGetInstance()
    
    -- Load saved geometry
    local x, y, w, h = UILib.DialogGeometry.Load(inst, dialogName, defaultW, defaultH)
    
    -- Default style includes resize border
    style = style or (wx.wxDEFAULT_DIALOG_STYLE + wx.wxRESIZE_BORDER)
    
    -- Create dialog
    local dialog = wx.wxDialog(parent, wx.wxID_ANY, title, 
                               wx.wxPoint(x, y), wx.wxSize(w, h), style)
    
    -- Store dialog name for save on close
    dialog.GeometryName = dialogName
    
    -- Add close handler to save geometry
    dialog:Connect(wx.wxEVT_CLOSE_WINDOW, function(event)
        local pos = dialog:GetPosition()
        local size = dialog:GetSize()
        UILib.DialogGeometry.Save(inst, dialog.GeometryName, 
                                  pos:GetX(), pos:GetY(), 
                                  size:GetWidth(), size:GetHeight())
        event:Skip()  -- Continue with close
    end)
    
    return dialog
end

-- Create dialog with panel and sizer
function UILib.ResizableDialog.CreateWithPanel(parent, title, dialogName, defaultW, defaultH)
    local dialog = UILib.ResizableDialog.Create(parent, title, dialogName, defaultW, defaultH)
    local panel = wx.wxPanel(dialog, wx.wxID_ANY)
    local mainSizer = wx.wxBoxSizer(wx.wxVERTICAL)
    
    -- Set minimum size
    dialog:SetMinSize(wx.wxSize(200, 150))
    
    return dialog, panel, mainSizer
end

-- ============================================
-- CONTROLS - Standard UI Controls with Validation
-- ============================================

-- Create labeled number input
function UILib.Controls.CreateNumberInput(panel, label, value, width)
    local sizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
    
    -- Label
    local labelCtrl = wx.wxStaticText(panel, wx.wxID_ANY, label)
    sizer:Add(labelCtrl, 0, wx.wxALIGN_CENTER_VERTICAL + wx.wxRIGHT, 5)
    
    -- Input
    local input = wx.wxTextCtrl(panel, wx.wxID_ANY, tostring(value))
    if width then
        input:SetMinSize(wx.wxSize(width, -1))
    end
    sizer:Add(input, 1, wx.wxALIGN_CENTER_VERTICAL)
    
    -- Add validation helper
    function input:GetNumber(defaultValue)
        local val = tonumber(self:GetValue())
        return val or defaultValue or 0
    end
    
    return sizer, input, labelCtrl
end

-- Create radio box control
function UILib.Controls.CreateRadioBox(panel, label, choices, selected, columns)
    columns = columns or 1
    local radioBox = wx.wxRadioBox(panel, wx.wxID_ANY,
        label, wx.wxDefaultPosition, wx.wxDefaultSize,
        choices, columns, wx.wxRA_SPECIFY_COLS)
    radioBox:SetSelection(selected or 0)
    return radioBox
end

-- Create slider with text input combo
function UILib.Controls.CreateSliderCombo(panel, label, minVal, maxVal, value, step)
    local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
    
    -- Label
    if label and label ~= "" then
        local labelCtrl = wx.wxStaticText(panel, wx.wxID_ANY, label)
        sizer:Add(labelCtrl, 0, wx.wxBOTTOM, 3)
    end
    
    -- Slider and text box horizontal sizer
    local hSizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
    
    -- Slider
    local slider = wx.wxSlider(panel, wx.wxID_ANY, value, minVal, maxVal,
                               wx.wxDefaultPosition, wx.wxSize(200, -1))
    
    -- Text input
    local textCtrl = wx.wxTextCtrl(panel, wx.wxID_ANY, tostring(value),
                                   wx.wxDefaultPosition, wx.wxSize(60, -1))
    
    hSizer:Add(slider, 1, wx.wxALIGN_CENTER_VERTICAL + wx.wxRIGHT, 5)
    hSizer:Add(textCtrl, 0, wx.wxALIGN_CENTER_VERTICAL)
    
    sizer:Add(hSizer, 0, wx.wxEXPAND)
    
    -- Sync slider and text
    slider:Connect(wx.wxEVT_SLIDER, function(event)
        textCtrl:SetValue(tostring(slider:GetValue()))
        event:Skip()
    end)
    
    textCtrl:Connect(wx.wxEVT_TEXT, function(event)
        local val = tonumber(textCtrl:GetValue())
        if val and val >= minVal and val <= maxVal then
            slider:SetValue(val)
        end
        event:Skip()
    end)
    
    return sizer, slider, textCtrl
end

-- Create choice dropdown
function UILib.Controls.CreateChoice(panel, label, choices, selection)
    local sizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
    
    if label and label ~= "" then
        local labelCtrl = wx.wxStaticText(panel, wx.wxID_ANY, label)
        sizer:Add(labelCtrl, 0, wx.wxALIGN_CENTER_VERTICAL + wx.wxRIGHT, 5)
    end
    
    local choice = wx.wxChoice(panel, wx.wxID_ANY, 
                               wx.wxDefaultPosition, wx.wxDefaultSize, choices)
    choice:SetSelection(selection or 0)
    sizer:Add(choice, 1, wx.wxALIGN_CENTER_VERTICAL)
    
    return sizer, choice
end

-- Create radio box
function UILib.Controls.CreateRadioBox(panel, label, choices, selection, columns)
    columns = columns or 1
    local radioBox = wx.wxRadioBox(panel, wx.wxID_ANY, label,
                                   wx.wxDefaultPosition, wx.wxDefaultSize,
                                   choices, columns, wx.wxRA_SPECIFY_COLS)
    radioBox:SetSelection(selection or 0)
    return radioBox
end

-- Create checkbox
function UILib.Controls.CreateCheckBox(panel, label, checked)
    local checkBox = wx.wxCheckBox(panel, wx.wxID_ANY, label)
    checkBox:SetValue(checked or false)
    return checkBox
end

-- Create file picker
function UILib.Controls.CreateFilePicker(panel, label, path, wildcard)
    local sizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
    
    if label and label ~= "" then
        local labelCtrl = wx.wxStaticText(panel, wx.wxID_ANY, label)
        sizer:Add(labelCtrl, 0, wx.wxALIGN_CENTER_VERTICAL + wx.wxRIGHT, 5)
    end
    
    local picker = wx.wxFilePickerCtrl(panel, wx.wxID_ANY, path or "",
                                       "Select File", wildcard or "*.*",
                                       wx.wxDefaultPosition, wx.wxDefaultSize,
                                       wx.wxFLP_USE_TEXTCTRL + wx.wxFLP_OPEN)
    sizer:Add(picker, 1, wx.wxALIGN_CENTER_VERTICAL)
    
    return sizer, picker
end

-- Create standard OK/Cancel button sizer
function UILib.Controls.CreateButtonSizer(panel, okText, cancelText)
    local buttonSizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
    local okBtn = wx.wxButton(panel, wx.wxID_OK, okText or "OK")
    local cancelBtn = wx.wxButton(panel, wx.wxID_CANCEL, cancelText or "Cancel")
    buttonSizer:Add(okBtn, 0, wx.wxRIGHT, 5)
    buttonSizer:Add(cancelBtn, 0)
    return buttonSizer, okBtn, cancelBtn
end

-- ============================================
-- MSG - Standard Message Dialogs
-- ============================================

-- Get parent window for dialogs
function UILib.Msg.GetParent()
    local parent = wx.NULL
    local app = wx.wxGetApp()
    if app then
        local ok, top = pcall(function() return app:GetTopWindow() end)
        if ok and top then parent = top end
    end
    return parent
end

-- Show information dialog
function UILib.Msg.Info(message, title)
    title = title or "Information"
    wx.wxMessageBox(message, title, wx.wxOK + wx.wxICON_INFORMATION, UILib.Msg.GetParent())
end

-- Show error dialog
function UILib.Msg.Error(message, title)
    title = title or "Error"
    wx.wxMessageBox(message, title, wx.wxOK + wx.wxICON_ERROR, UILib.Msg.GetParent())
end

-- Show warning dialog
function UILib.Msg.Warning(message, title)
    title = title or "Warning"
    wx.wxMessageBox(message, title, wx.wxOK + wx.wxICON_WARNING, UILib.Msg.GetParent())
end

-- Show yes/no dialog
function UILib.Msg.YesNo(message, title)
    title = title or "Confirm"
    local result = wx.wxMessageBox(message, title, 
                                   wx.wxYES_NO + wx.wxICON_QUESTION, UILib.Msg.GetParent())
    return result == wx.wxYES
end

-- Show yes/no/cancel dialog
function UILib.Msg.YesNoCancel(message, title)
    title = title or "Confirm"
    local result = wx.wxMessageBox(message, title, 
                                   wx.wxYES_NO + wx.wxCANCEL + wx.wxICON_QUESTION, 
                                   UILib.Msg.GetParent())
    if result == wx.wxYES then return "yes"
    elseif result == wx.wxNO then return "no"
    else return "cancel"
    end
end

-- Aliases for backward compatibility with scripts
UILib.Msg.ShowInfo = UILib.Msg.Info
UILib.Msg.ShowError = UILib.Msg.Error
UILib.Msg.ShowWarning = UILib.Msg.Warning

-- ============================================
-- VALIDATE - Input Validation Functions
-- ============================================

-- Validate numeric range
function UILib.Validate.NumericRange(value, min, max, name)
    name = name or "Value"
    
    if type(value) ~= "number" then
        return false, name .. " must be a number"
    end
    
    if min and value < min then
        return false, string.format("%s must be at least %g", name, min)
    end
    
    if max and value > max then
        return false, string.format("%s must be at most %g", name, max)
    end
    
    return true, nil
end

-- Validate file path exists
function UILib.Validate.FileExists(path, name)
    name = name or "File"
    
    if not path or path == "" then
        return false, name .. " path is empty"
    end
    
    local file = io.open(path, "r")
    if not file then
        return false, name .. " not found: " .. path
    end
    
    file:close()
    return true, nil
end

-- Validate image dimensions
function UILib.Validate.ImageDimensions(width, height, maxWidth, maxHeight)
    if width <= 0 or height <= 0 then
        return false, "Invalid image dimensions"
    end
    
    if maxWidth and width > maxWidth then
        return false, string.format("Image width (%d) exceeds maximum (%d)", width, maxWidth)
    end
    
    if maxHeight and height > maxHeight then
        return false, string.format("Image height (%d) exceeds maximum (%d)", height, maxHeight)
    end
    
    return true, nil
end

-- ============================================
-- PROGRESS - Progress Dialog Management
-- ============================================

-- Create progress dialog
function UILib.Progress.Create(title, message, maximum, parent)
    parent = parent or UILib.Msg.GetParent()
    
    local dialog = wx.wxProgressDialog(title, message, maximum or 100, parent,
                                       wx.wxPD_APP_MODAL + wx.wxPD_AUTO_HIDE + 
                                       wx.wxPD_CAN_ABORT + wx.wxPD_ELAPSED_TIME +
                                       wx.wxPD_ESTIMATED_TIME + wx.wxPD_REMAINING_TIME)
    
    -- Add helper methods
    function dialog:UpdateProgress(value, message)
        local continue = self:Update(value, message)
        return continue
    end
    
    function dialog:SetIndeterminate()
        self:Pulse()
    end
    
    return dialog
end

-- ============================================
-- IMAGE - Image Handling Functions
-- ============================================

-- Load and validate image
function UILib.Image.LoadValidated(path, maxWidth, maxHeight)
    if not path or path == "" then
        return nil, "No image path specified"
    end
    
    -- Check file exists
    local file = io.open(path, "rb")
    if not file then
        return nil, "Image file not found: " .. path
    end
    file:close()
    
    -- Load image
    local image = wx.wxImage(path)
    if not image:IsOk() then
        return nil, "Failed to load image: " .. path
    end
    
    -- Validate dimensions
    local width = image:GetWidth()
    local height = image:GetHeight()
    
    local valid, err = UILib.Validate.ImageDimensions(width, height, maxWidth, maxHeight)
    if not valid then
        image:delete()
        return nil, err
    end
    
    return image, nil
end

-- Transform image (scale, rotate, flip)
function UILib.Image.Transform(image, scaleX, scaleY, rotate, flipX, flipY)
    if not image or not image:IsOk() then
        return nil, "Invalid image"
    end
    
    local transformed = image:Copy()
    
    -- Scale
    if scaleX and scaleY then
        local newWidth = math.floor(transformed:GetWidth() * scaleX)
        local newHeight = math.floor(transformed:GetHeight() * scaleY)
        transformed = transformed:Scale(newWidth, newHeight, wx.wxIMAGE_QUALITY_HIGH)
    end
    
    -- Rotate
    if rotate and rotate ~= 0 then
        -- Convert degrees to radians
        local radians = math.rad(rotate)
        transformed = transformed:Rotate(radians, wx.wxPoint(transformed:GetWidth()/2, 
                                                             transformed:GetHeight()/2))
    end
    
    -- Flip
    if flipX then
        transformed = transformed:Mirror()
    end
    
    if flipY then
        transformed = transformed:Mirror(false)
    end
    
    return transformed, nil
end

-- ============================================
-- WIZARD - Multi-Step Wizard Support
-- ============================================

-- Create wizard structure
function UILib.Wizard.Create(title)
    local wizard = {
        title = title,
        steps = {},
        currentStep = 1,
        data = {}
    }
    
    -- Add step
    function wizard:AddStep(name, createFunc, validateFunc)
        table.insert(self.steps, {
            name = name,
            create = createFunc,
            validate = validateFunc
        })
    end
    
    -- Navigate to step
    function wizard:GoToStep(stepNum)
        if stepNum < 1 or stepNum > #self.steps then
            return false
        end
        
        -- Validate current step before moving
        if self.steps[self.currentStep].validate then
            local valid, err = self.steps[self.currentStep].validate(self.data)
            if not valid then
                UILib.Msg.Error(err or "Validation failed")
                return false
            end
        end
        
        self.currentStep = stepNum
        return true
    end
    
    -- Next step
    function wizard:Next()
        return self:GoToStep(self.currentStep + 1)
    end
    
    -- Previous step
    function wizard:Previous()
        return self:GoToStep(self.currentStep - 1)
    end
    
    -- Check if can go next/previous
    function wizard:CanGoNext()
        return self.currentStep < #self.steps
    end
    
    function wizard:CanGoPrevious()
        return self.currentStep > 1
    end
    
    return wizard
end

-- Return the library
return UILib