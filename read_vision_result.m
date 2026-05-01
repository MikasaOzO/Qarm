function [found, x, y, z, observe_id, place_id] = read_vision_result()

    found = false;
    x = 0;
    y = 0;
    z = 0;
    observe_id = -1;
    place_id = 0;

    filename = 'F:\桌面\vision_result.json'; % This need replace to actual position of json file

    if exist(filename, 'file') == 2
        try
            fid = fopen(filename, 'r');
            raw = fread(fid, inf);
            str = char(raw');
            fclose(fid);

            data = jsondecode(str);

            found = logical(data.found);
            observe_id = double(data.observe_id);

            if isfield(data, 'place_id') && ~isempty(data.place_id)
                place_id = double(data.place_id);
            else
                place_id = 0;
            end

            if found && isfield(data, 'camera_xyz') && ~isempty(data.camera_xyz)
                x = double(data.camera_xyz(1));
                y = double(data.camera_xyz(2));
                z = double(data.camera_xyz(3));
            end

        catch ME
            disp('Error reading JSON:');
            disp(ME.message);
        end
    else
        disp('vision_result.json not found.');
    end
end