function SilenceRemovalGUI
    % Create a UI figure
    fig = uifigure('Name', 'Silence Removal System', 'Position', [100, 100, 500, 450]);

    % Add UI components
    btnLoad = uibutton(fig, 'push', 'Text', 'Load Audio', 'Position', [50, 400, 100, 30], ...
                       'ButtonPushedFcn', @(btn, event) loadAudio());
    btnRecord = uibutton(fig, 'push', 'Text', 'Record Audio', 'Position', [200, 400, 120, 30], ...
                         'ButtonPushedFcn', @(btn, event) recordAudio());
    btnProcess = uibutton(fig, 'push', 'Text', 'Remove Silence', 'Position', [350, 400, 120, 30], ...
                          'ButtonPushedFcn', @(btn, event) processAudio());
    btnPlayOriginal = uibutton(fig, 'push', 'Text', 'Play Original', 'Position', [50, 350, 100, 30], ...
                               'ButtonPushedFcn', @(btn, event) playAudio(1));
    btnPlayProcessed = uibutton(fig, 'push', 'Text', 'Play Processed', 'Position', [200, 350, 120, 30], ...
                                'ButtonPushedFcn', @(btn, event) playAudio(2));
    btnStop = uibutton(fig, 'push', 'Text', 'Stop Audio', 'Position', [350, 350, 120, 30], ...
                       'ButtonPushedFcn', @(btn, event) stopAudio());
    btnSave = uibutton(fig, 'push', 'Text', 'Save Processed Audio', 'Position', [350, 300, 120, 30], ...
                       'ButtonPushedFcn', @(btn, event) saveAudio());

    % Axes for plotting waveforms
    ax1 = uiaxes(fig, 'Position', [50, 150, 400, 120]);
    title(ax1, 'Original Audio');
    
    ax2 = uiaxes(fig, 'Position', [50, 20, 400, 120]);
    title(ax2, 'Processed Audio');

    % Global variables to store audio data
    global audio fs processed_audio recorder;

    % Initialize processed_audio as empty
    processed_audio = [];

    % Load Audio Function
    function loadAudio()
        [file, path] = uigetfile('*.wav', 'Select an Audio File');
        if isequal(file, 0)
            return;
        end
        [audio, fs] = audioread(fullfile(path, file));

        % Convert stereo to mono (if necessary)
        if size(audio, 2) == 2 % Check if audio is stereo
            audio = mean(audio, 2); % Average the two channels
        end

        % Clear processed_audio when loading new audio
        processed_audio = [];
        cla(ax2); % Clear processed audio plot
        title(ax2, 'Processed Audio');

        plot(ax1, audio); % Plot original audio
        title(ax1, 'Original Audio');
    end

    % Record Audio Function
    function recordAudio()
        fs = 44100; % Sampling frequency
        recorder = audiorecorder(fs, 16, 1); % Create recorder object
        uialert(fig, 'Recording... Speak now!', 'Recording');
        record(recorder); % Start recording
    end

    % Stop Audio Function
    function stopAudio()
        clear sound; % Stop any audio playback
        if exist('recorder', 'var') && isobject(recorder) && strcmp(recorder.Running, 'on')
            stop(recorder); % Stop recording
            audio = getaudiodata(recorder); % Get recorded audio
            fs = recorder.SampleRate; % Get sampling rate

            % Clear processed_audio when stopping recording
            processed_audio = [];
            cla(ax2); % Clear processed audio plot
            title(ax2, 'Processed Audio');

            plot(ax1, audio); % Plot recorded audio
            title(ax1, 'Recorded Audio');
        end
    end

    % Process Audio Function (STE + ZCR + ACR Silence Removal)
    function processAudio()
        if isempty(audio)
            uialert(fig, 'Please load or record an audio file first.', 'Error');
            return;
        end

        % Frame parameters
        frame_size = round(0.02 * fs); % 20ms frame size
        overlap = round(0.01 * fs); % 10ms overlap
        step_size = frame_size - overlap; % Step size for overlap-add

        % Initialize processed_audio as empty
        processed_audio = [];

        % Initialize arrays to store STE, ZCR, and ACR
        all_energy = [];
        all_zcr = [];
        all_acr = [];
        all_frame_indices = [];

        % Process audio in chunks to avoid memory issues
        chunk_size = 100000; % Process 100,000 samples at a time
        num_chunks = ceil(length(audio) / chunk_size);

        for chunk_idx = 1:num_chunks
            % Get the current chunk
            start_idx = (chunk_idx - 1) * chunk_size + 1;
            end_idx = min(chunk_idx * chunk_size, length(audio));
            chunk = audio(start_idx:end_idx);

            % Buffer the chunk into frames
            frames = buffer(chunk, frame_size, overlap, 'nodelay');

            % Compute Short-Time Energy (STE)
            energy = sum(frames.^2);

            % Compute Zero-Crossing Rate (ZCR)
            zcr = sum(abs(diff(sign(frames)))) / 2;

            % Compute Auto-Correlation (ACR)
            acr = zeros(1, size(frames, 2));
            for i = 1:size(frames, 2)
                acr(i) = sum(frames(:, i) .* frames(:, i));
            end

            % Store STE, ZCR, and ACR for plotting
            all_energy = [all_energy, energy];
            all_zcr = [all_zcr, zcr];
            all_acr = [all_acr, acr];
            frame_indices = (1:length(energy)) + (chunk_idx - 1) * (length(energy));
            all_frame_indices = [all_frame_indices, frame_indices];

            % Normalize STE, ZCR, and ACR to the range [0, 1]
            energy_norm = (energy - min(energy)) / (max(energy) - min(energy));
            zcr_norm = (zcr - min(zcr)) / (max(zcr) - min(zcr));
            acr_norm = (acr - min(acr)) / (max(acr) - min(acr));

            % Combine STE, ZCR, and ACR using a weighted sum
            alpha = 0.5; % Weight for STE
            beta = 0.3; % Weight for ZCR
            gamma = 0.2; % Weight for ACR
            combined_metric = alpha * energy_norm + beta * (1 - zcr_norm) + gamma * acr_norm;

            % Set dynamic threshold (e.g., 0.3)
            threshold = 0.3;

            % Smooth the combined metric using a moving average filter
            combined_metric_smoothed = movmean(combined_metric, 5);

            % Keep only high-energy frames (remove silence)
            voiced_frames = frames(:, combined_metric_smoothed > threshold);

            % Reconstruct the chunk using overlap-add
            chunk_processed = zeros((size(voiced_frames, 2) - 1) * step_size + frame_size, 1);
            for i = 1:size(voiced_frames, 2)
                start_frame_idx = (i - 1) * step_size + 1;
                end_frame_idx = start_frame_idx + frame_size - 1;
                chunk_processed(start_frame_idx:end_frame_idx) = ...
                    chunk_processed(start_frame_idx:end_frame_idx) + voiced_frames(:, i);
            end

            % Append the processed chunk to the final output
            processed_audio = [processed_audio; chunk_processed];
        end

        % Normalize the output to prevent clipping
        processed_audio = processed_audio / max(abs(processed_audio));

        % Plot processed audio
        plot(ax2, processed_audio);
        title(ax2, 'Processed Audio');

        % Plot Short-Time Energy (STE), ZCR, and ACR
        figure;
        subplot(3, 1, 1);
        plot(all_frame_indices, all_energy, 'b', 'LineWidth', 1.5); % Plot STE in blue
        title('Short-Time Energy (STE)');
        xlabel('Frame Index');
        ylabel('Energy');
        grid on;

        subplot(3, 1, 2);
        plot(all_frame_indices, all_zcr, 'r', 'LineWidth', 1.5); % Plot ZCR in red
        title('Zero-Crossing Rate (ZCR)');
        xlabel('Frame Index');
        ylabel('ZCR');
        grid on;

        subplot(3, 1, 3);
        plot(all_frame_indices, all_acr, 'g', 'LineWidth', 1.5); % Plot ACR in green
        title('Auto-Correlation (ACR)');
        xlabel('Frame Index');
        ylabel('ACR');
        grid on;
    end

    % Play Audio Function
    function playAudio(type)
        if type == 1 && ~isempty(audio)
            sound(audio, fs); % Play original audio
        elseif type == 2 && ~isempty(processed_audio)
            sound(processed_audio, fs); % Play processed audio
        else
            uialert(fig, 'No audio to play.', 'Error');
        end
    end

    % Save Processed Audio Function
    function saveAudio()
        if isempty(processed_audio)
            uialert(fig, 'No processed audio to save.', 'Error');
            return;
        end
        [file, path] = uiputfile('*.wav', 'Save Processed Audio');
        if isequal(file, 0)
            return;
        end
        audiowrite(fullfile(path, file), processed_audio, fs);
        uialert(fig, 'Processed audio saved successfully.', 'Success');
    end
end