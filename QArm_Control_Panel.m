function QArm_Control_Panel()
% QArm Manual Control Panel  (English Edition)
%
% Keyboard shortcuts:
%   A / D    - Base rotate left / right       (Joint 1)
%   W / S    - Shoulder up / down             (Joint 2)
%   Q / E    - Elbow up / down                (Joint 3)
%   Z / C    - Wrist rotate                   (Joint 4)
%   SPACE    - Toggle gripper open / close
%   M        - Toggle manual / auto mode
%   R        - Reset all joints to home (zero)
%   ESC      - Emergency stop
%
% Workspace variables updated in real-time:
%   qarm_joints        [4x1 double, radians]
%   qarm_gripper_open  [logical]
%   qarm_mode          [char: 'manual' | 'auto']
%   qarm_estop         [logical]

% ── Initial state ──────────────────────────────────────────
joints       = [0; 0; 0; 0];
gripper_open = true;
mode         = 'manual';
estop        = false;
step         = 0.05;   % keyboard step size (rad)

% Joint limits [min, max] in radians
jlim = [-pi,    pi;     % J1  Base
         -pi/2,  pi/2;  % J2  Shoulder
         -pi/2,  pi/2;  % J3  Elbow
         -pi,    pi];   % J4  Wrist

joint_labels = {'J1  Base        (A / D)', ...
                'J2  Shoulder    (W / S)', ...
                'J3  Elbow       (Q / E)', ...
                'J4  Wrist       (Z / C)'};

% ── Colour palette ─────────────────────────────────────────
BG      = [0.10 0.11 0.14];
PANEL   = [0.16 0.17 0.21];
CARD    = [0.20 0.22 0.27];
WHITE   = [1.00 1.00 1.00];
GRAY    = [0.55 0.58 0.65];
BLUE    = [0.18 0.52 0.92];
GREEN   = [0.08 0.70 0.38];
ORANGE  = [0.92 0.52 0.08];
RED     = [0.88 0.12 0.15];
YELLOW  = [0.98 0.78 0.08];
TEAL    = [0.08 0.72 0.72];

% ── Window ─────────────────────────────────────────────────
fig = uifigure( ...
    'Name',         'QArm Control Panel', ...
    'Position',     [120 60 560 700], ...
    'Color',        BG, ...
    'Resize',       'off', ...
    'KeyPressFcn',  @keyHandler);

% ── Header bar ─────────────────────────────────────────────
uilabel(fig, ...
    'Text',               'QArm  Control Panel', ...
    'Position',           [0 656 560 44], ...
    'FontSize',           22, 'FontWeight', 'bold', ...
    'FontColor',          WHITE, ...
    'BackgroundColor',    PANEL, ...
    'HorizontalAlignment','center');

% ── Mode & E-Stop buttons ──────────────────────────────────
mode_btn = uibutton(fig, 'push', ...
    'Text',             'MODE: MANUAL', ...
    'Position',         [16 600 254 46], ...
    'FontSize',         13, 'FontWeight', 'bold', ...
    'BackgroundColor',  BLUE, 'FontColor', WHITE, ...
    'ButtonPushedFcn',  @toggleMode);

estop_btn = uibutton(fig, 'push', ...
    'Text',             'EMERGENCY STOP', ...
    'Position',         [290 600 254 46], ...
    'FontSize',         13, 'FontWeight', 'bold', ...
    'BackgroundColor',  RED, 'FontColor', WHITE, ...
    'ButtonPushedFcn',  @emergencyStop);

% ── Joint sliders ──────────────────────────────────────────
sliders    = gobjects(4,1);
val_labels = gobjects(4,1);
deg_bars   = gobjects(4,1);  % coloured progress indicators

for i = 1:4
    yb = 590 - i*118;   % base y for this joint card

    % Card background
    uipanel(fig, ...
        'Position',         [12 yb 536 108], ...
        'BackgroundColor',  CARD, ...
        'BorderType',       'none');

    % Joint name
    uilabel(fig, ...
        'Text',      joint_labels{i}, ...
        'Position',  [24 yb+78 260 22], ...
        'FontSize',  12, 'FontWeight', 'bold', ...
        'FontColor', WHITE);

    % Value display
    val_labels(i) = uilabel(fig, ...
        'Text',               '0.00 rad  (0.0°)', ...
        'Position',           [300 yb+76 238 24], ...
        'FontSize',           11, 'FontWeight', 'bold', ...
        'FontColor',          YELLOW, ...
        'HorizontalAlignment','right');

    % Limit labels
    uilabel(fig, ...
        'Text',      sprintf('%.0f°', rad2deg(jlim(i,1))), ...
        'Position',  [24 yb+10 48 18], ...
        'FontSize',  9, 'FontColor', GRAY);
    uilabel(fig, ...
        'Text',      '0°', ...
        'Position',  [256 yb+10 48 18], ...
        'FontSize',  9, 'FontColor', GRAY, ...
        'HorizontalAlignment','center');
    uilabel(fig, ...
        'Text',      sprintf('%.0f°', rad2deg(jlim(i,2))), ...
        'Position',  [488 yb+10 48 18], ...
        'FontSize',  9, 'FontColor', GRAY, ...
        'HorizontalAlignment','right');

    % Slider
    sliders(i) = uislider(fig, ...
        'Limits',          [jlim(i,1) jlim(i,2)], ...
        'Value',           0, ...
        'Position',        [24 yb+44 512 3], ...
        'ValueChangedFcn', @(s,~) sliderMoved(i, s.Value));
end

% ── Gripper button ─────────────────────────────────────────
grip_btn = uibutton(fig, 'push', ...
    'Text',             'GRIPPER:  OPEN   (Space)', ...
    'Position',         [16 72 528 58], ...
    'FontSize',         16, 'FontWeight', 'bold', ...
    'BackgroundColor',  GREEN, 'FontColor', WHITE, ...
    'ButtonPushedFcn',  @toggleGripper);

% ── Reset button ───────────────────────────────────────────
uibutton(fig, 'push', ...
    'Text',             'RESET TO HOME  (R)', ...
    'Position',         [16 32 528 34], ...
    'FontSize',         11, ...
    'BackgroundColor',  TEAL, 'FontColor', WHITE, ...
    'ButtonPushedFcn',  @resetHome);

% ── Status bar ─────────────────────────────────────────────
status_lbl = uilabel(fig, ...
    'Text',               'Ready  —  Manual mode  |  Click panel then use keyboard', ...
    'Position',           [0 0 560 28], ...
    'FontSize',           10, ...
    'FontColor',          WHITE, ...
    'BackgroundColor',    PANEL, ...
    'HorizontalAlignment','center');

% ── Keyboard hint ──────────────────────────────────────────
uilabel(fig, ...
    'Text',               'A/D  W/S  Q/E  Z/C  =  joints    Space  =  gripper    M  =  mode    R  =  reset    ESC  =  stop', ...
    'Position',           [0 136 560 22], ...
    'FontSize',           9, ...
    'FontColor',          GRAY, ...
    'HorizontalAlignment','center');

% Initial workspace write
syncWorkspace();

% ══════════════════════════════════════════════════════════
%                     CALLBACKS
% ══════════════════════════════════════════════════════════

    function sliderMoved(idx, val)
        if estop, sliders(idx).Value = joints(idx); return; end
        joints(idx) = val;
        refreshJointDisplay(idx);
        setStatus(sprintf('J%d moved to %.2f rad  (%.1f°)', idx, val, rad2deg(val)));
        syncWorkspace();
    end

    function toggleGripper(~,~)
        if estop, return; end
        gripper_open = ~gripper_open;
        if gripper_open
            grip_btn.Text            = 'GRIPPER:  OPEN   (Space)';
            grip_btn.BackgroundColor = GREEN;
            setStatus('Gripper OPENED');
        else
            grip_btn.Text            = 'GRIPPER:  CLOSED   (Space)';
            grip_btn.BackgroundColor = ORANGE;
            setStatus('Gripper CLOSED');
        end
        syncWorkspace();
    end

    function toggleMode(~,~)
        if estop, return; end
        if strcmp(mode, 'manual')
            mode = 'auto';
            mode_btn.Text            = 'MODE: AUTO';
            mode_btn.BackgroundColor = YELLOW;
            mode_btn.FontColor       = [0 0 0];
            setStatus('Switched to AUTO mode  —  Simulink IK in control');
        else
            mode = 'manual';
            mode_btn.Text            = 'MODE: MANUAL';
            mode_btn.BackgroundColor = BLUE;
            mode_btn.FontColor       = WHITE;
            setStatus('Switched to MANUAL mode  —  Panel in control');
        end
        syncWorkspace();
    end

    function resetHome(~,~)
        if estop, return; end
        joints = [0;0;0;0];
        for k = 1:4
            sliders(k).Value = 0;
            refreshJointDisplay(k);
        end
        setStatus('All joints reset to home position (0 rad)');
        syncWorkspace();
    end

    function emergencyStop(~,~)
        estop  = true;
        joints = [0;0;0;0];
        for k = 1:4
            sliders(k).Value    = 0;
            sliders(k).Enable   = 'off';
            refreshJointDisplay(k);
        end
        estop_btn.Text            = '!! STOPPED !!';
        estop_btn.BackgroundColor = [0.35 0.05 0.05];
        mode_btn.Enable           = 'off';
        grip_btn.Enable           = 'off';
        status_lbl.BackgroundColor = RED;
        status_lbl.FontColor       = WHITE;
        setStatus('EMERGENCY STOP ACTIVATED  —  Close and reopen panel to reset');
        syncWorkspace();
    end

    function keyHandler(~, ev)
        if estop, return; end
        moved = true;
        switch lower(ev.Key)
            case 'a';      joints(1) = clamp(joints(1) + step, jlim(1,:));
            case 'd';      joints(1) = clamp(joints(1) - step, jlim(1,:));
            case 'w';      joints(2) = clamp(joints(2) + step, jlim(2,:));
            case 's';      joints(2) = clamp(joints(2) - step, jlim(2,:));
            case 'q';      joints(3) = clamp(joints(3) + step, jlim(3,:));
            case 'e';      joints(3) = clamp(joints(3) - step, jlim(3,:));
            case 'z';      joints(4) = clamp(joints(4) + step, jlim(4,:));
            case 'c';      joints(4) = clamp(joints(4) - step, jlim(4,:));
            case 'space';  moved = false; toggleGripper([],[]); return;
            case 'escape'; moved = false; emergencyStop([],[]);  return;
            case 'm';      moved = false; toggleMode([],[]);      return;
            case 'r';      moved = false; resetHome([],[]);       return;
            otherwise;     moved = false;
        end
        if moved
            for k = 1:4
                sliders(k).Value = joints(k);
                refreshJointDisplay(k);
            end
            syncWorkspace();
        end
    end

% ══════════════════════════════════════════════════════════
%                     HELPERS
% ══════════════════════════════════════════════════════════

    function refreshJointDisplay(idx)
        val = joints(idx);
        val_labels(idx).Text = sprintf('%.2f rad  (%.1f°)', val, rad2deg(val));
    end

    function v = clamp(v, lim)
        v = max(lim(1), min(lim(2), v));
    end

    function setStatus(msg)
        status_lbl.Text = sprintf('  %s  |  Mode: %s', msg, upper(mode));
    end

    function syncWorkspace()
    assignin('base', 'qarm_joints',       joints);
    assignin('base', 'qarm_gripper_open', gripper_open);
    assignin('base', 'qarm_mode',         mode);
    assignin('base', 'qarm_estop',        estop);

    blk = 'PickAndPlace_Hardware/Manual_Joints';
    if bdIsLoaded('PickAndPlace_Hardware') && getSimulinkBlockHandle(blk) ~= -1
        set_param(blk, 'Value', mat2str(joints));
    end

    gripBlk = 'PickAndPlace_Hardware/Manual_Gripper';
    if bdIsLoaded('PickAndPlace_Hardware') && getSimulinkBlockHandle(gripBlk) ~= -1
    set_param(gripBlk, 'Value', num2str(~gripper_open));
    end

end

end
