%% install_manual_control.m
% One-shot script to add manual control interface to the QArm Simulink model.
% Run this with the target .slx model already open in Simulink.
%
% What this script does:
%   1. Finds the IK block and QArm Hardware block automatically
%   2. Deletes the direct IK Config → QArm Hardware line
%   3. Adds a Switch block (manual/auto selector)
%   4. Adds a Read_Manual_Joints MATLAB Function block
%   5. Connects: IK→Switch(1), Automate?→Switch(2), ManualJoints→Switch(3)
%   6. Connects Switch output → QArm Hardware
%   7. Writes the function code into Read_Manual_Joints automatically
%
% Usage:
%   1. Open your .slx model in Simulink
%   2. Run: install_manual_control
%   3. Ctrl+S to save
%
% After installation:
%   - Automate? = 0  →  Manual mode  (panel controls the arm)
%   - Automate? = 1  →  Auto mode    (IK/Stateflow controls the arm)

clc;
fprintf('=================================================\n');
fprintf('  QArm Manual Control Interface Installer\n');
fprintf('=================================================\n\n');

% ---- Find the open Simulink model ----
open_models = find_system('SearchDepth', 0, 'Type', 'block_diagram');
mdl = '';
for i = 1:length(open_models)
    if ~strcmp(open_models{i}, 'simulink')
        mdl = open_models{i};
        break;
    end
end

if isempty(mdl)
    error('No Simulink model is open. Please open your .slx file first.');
end
fprintf('[OK] Model found: %s\n', mdl);

% ---- Check if already installed ----
existing = find_system(mdl, 'SearchDepth', 1, 'Name', 'Manual_Auto_Switch');
if ~isempty(existing)
    fprintf('\n[WARNING] Manual_Auto_Switch already exists in this model.\n');
    fprintf('          Skipping installation to avoid duplicates.\n');
    fprintf('          If you want to reinstall, delete Manual_Auto_Switch\n');
    fprintf('          and Read_Manual_Joints blocks first, then re-run.\n');
    return;
end

% ---- Find IK block ----
fprintf('\n[1/6] Searching for IK block...\n');
all_blocks = find_system(mdl, 'SearchDepth', 1, 'Type', 'block');
ik_block  = '';
hw_block  = '';

for i = 1:length(all_blocks)
    name = get_param(all_blocks{i}, 'Name');
    if contains(name, 'End-Effector Transform', 'IgnoreCase', true) || ...
       contains(name, 'Joint Space', 'IgnoreCase', true) && ...
       contains(name, 'End-Effector', 'IgnoreCase', true)
        ik_block = all_blocks{i};
        fprintf('     IK block: %s\n', name);
    end
    if contains(name, 'QArm', 'IgnoreCase', true) && ...
       (contains(name, 'Hardware', 'IgnoreCase', true) || ...
        contains(name, 'I/O', 'IgnoreCase', true))
        hw_block = all_blocks{i};
        fprintf('     Hardware block: %s\n', name);
    end
end

if isempty(ik_block) || isempty(hw_block)
    fprintf('\n[ERROR] Could not auto-find IK or Hardware block.\n');
    fprintf('Available blocks:\n');
    for i = 1:length(all_blocks)
        fprintf('  %s\n', get_param(all_blocks{i}, 'Name'));
    end
    error('Please check block names above and contact support.');
end

% ---- Find IK output port 1 (Config) → QArm Hardware line ----
fprintf('\n[2/6] Finding IK Config → Hardware connection...\n');
ik_ph   = get_param(ik_block, 'PortHandles');
cfg_line = -1;
cfg_port = -1;
hw_dst_port = 1;

for p = 1:length(ik_ph.Outport)
    lh = get_param(ik_ph.Outport(p), 'Line');
    if lh ~= -1
        dst_h = get_param(lh, 'DstBlockHandle');
        if dst_h ~= -1
            dst_name = getfullname(dst_h);
            if strcmp(dst_name, hw_block)
                cfg_line = lh;
                cfg_port = p;
                % Find which input port of hw_block receives this line
                hw_ph = get_param(hw_block, 'PortHandles');
                for pp = 1:length(hw_ph.Inport)
                    if get_param(hw_ph.Inport(pp), 'Line') == lh
                        hw_dst_port = pp;
                        break;
                    end
                end
                fprintf('     IK output port %d → Hardware input port %d\n', p, hw_dst_port);
                break;
            end
        end
    end
end

if cfg_line == -1
    error(['Could not find direct connection from IK to QArm Hardware.\n' ...
           'The signal may go through Goto/From tags. Please connect manually.']);
end

% ---- Find Automate? block ----
fprintf('\n[3/6] Finding Automate? block...\n');
auto_block = '';
for i = 1:length(all_blocks)
    name = get_param(all_blocks{i}, 'Name');
    if contains(name, 'automate', 'IgnoreCase', true) || ...
       contains(name, 'Automate', 'IgnoreCase', true)
        auto_block = all_blocks{i};
        fprintf('     Found: %s\n', name);
        break;
    end
end
if isempty(auto_block)
    error('Could not find Automate? block. Check block name in your model.');
end

% ---- Calculate positions for new blocks ----
ik_pos  = get_param(ik_block,  'Position');
hw_pos  = get_param(hw_block,  'Position');

sw_cx = round((ik_pos(3) + hw_pos(1)) / 2);
sw_cy = round((ik_pos(2) + ik_pos(4)) / 2);

sw_pos  = [sw_cx-25, sw_cy-40, sw_cx+25, sw_cy+40];
fn_pos  = [sw_cx-50, sw_cy+120, sw_cx+50, sw_cy+160];

% ---- Delete original line ----
fprintf('\n[4/6] Removing original IK → Hardware line...\n');
delete_line(mdl, cfg_line);
fprintf('     Done.\n');

% ---- Add Switch block ----
fprintf('\n[5/6] Adding Switch and Read_Manual_Joints blocks...\n');
sw_path = [mdl '/Manual_Auto_Switch'];
add_block('simulink/Signal Routing/Switch', sw_path, ...
    'Position',  sw_pos, ...
    'Criteria',  'u2 >= Threshold', ...
    'Threshold', '0.5');
fprintf('     Switch block added.\n');

% ---- Add MATLAB Function block ----
fn_path = [mdl '/Read_Manual_Joints'];
add_block('simulink/User-Defined Functions/MATLAB Function', fn_path, ...
    'Position', fn_pos);
fprintf('     Read_Manual_Joints block added.\n');

% ---- Write function code via Stateflow API ----
rt = sfroot();
m  = rt.find('-isa', 'Simulink.BlockDiagram', 'Name', mdl);
charts = m.find('-isa', 'Stateflow.EMChart');
code_written = false;
for k = 1:length(charts)
    if contains(charts(k).Path, 'Read_Manual_Joints')
        charts(k).Script = sprintf([...
            'function joints = Read_Manual_Joints()\n'...
            'coder.extrinsic(''evalin'');\n'...
            'joints = zeros(4,1);\n'...
            'joints = evalin(''base'',''qarm_joints(1:4)'');\n']);
        code_written = true;
        fprintf('     Function code written automatically.\n');
        break;
    end
end
if ~code_written
    fprintf('\n[ACTION REQUIRED] Could not write code automatically.\n');
    fprintf('Please double-click Read_Manual_Joints and paste this code:\n\n');
    fprintf('function joints = Read_Manual_Joints()\n');
    fprintf('coder.extrinsic(''evalin'');\n');
    fprintf('joints = zeros(4,1);\n');
    fprintf('joints = evalin(''base'',''qarm_joints(1:4)'');\n\n');
end

% ---- Connect all lines ----
fprintf('\n[6/6] Connecting all lines...\n');

[~, ik_name]  = fileparts(ik_block);
[~, hw_name]  = fileparts(hw_block);
[~, auto_name] = fileparts(auto_block);

% IK Config → Switch port 1
add_line(mdl, [ik_name '/1'], 'Manual_Auto_Switch/1', 'autorouting', 'smart');
fprintf('     IK Config → Switch(1) done.\n');

% Automate? → Switch port 2 (control)
% First check if Automate? already has a line we can branch from
auto_ph = get_param(auto_block, 'PortHandles');
add_line(mdl, [auto_name '/1'], 'Manual_Auto_Switch/2', 'autorouting', 'smart');
fprintf('     Automate? → Switch(2) done.\n');

% Read_Manual_Joints → Switch port 3
add_line(mdl, 'Read_Manual_Joints/1', 'Manual_Auto_Switch/3', 'autorouting', 'smart');
fprintf('     Read_Manual_Joints → Switch(3) done.\n');

% Switch → QArm Hardware
add_line(mdl, 'Manual_Auto_Switch/1', [hw_name '/' num2str(hw_dst_port)], 'autorouting', 'smart');
fprintf('     Switch → QArm Hardware(%d) done.\n', hw_dst_port);

% ---- Done ----
set_param(mdl, 'SimulationCommand', 'update');

fprintf('\n=================================================\n');
fprintf('  Installation COMPLETE!\n');
fprintf('=================================================\n');
fprintf('\nNext steps:\n');
fprintf('  1. Press Ctrl+S to save the model\n');
fprintf('  2. Run QArm_Control_Panel in MATLAB\n');
fprintf('  3. Set Automate? = 0 for manual mode\n');
fprintf('  4. Start simulation\n\n');
fprintf('Workspace variables written by the panel:\n');
fprintf('  qarm_joints       [4x1 rad]  - joint angles\n');
fprintf('  qarm_gripper_open [bool]     - gripper state\n');
fprintf('  qarm_mode         [string]   - manual / auto\n');
fprintf('  qarm_estop        [bool]     - emergency stop\n\n');
