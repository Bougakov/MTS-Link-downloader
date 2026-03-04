#!/usr/bin/env python3
import sys
import re
import json
import urllib.request
import subprocess
import os
from datetime import datetime

def extract_ids(url):
    session_match = re.search(r'/record(?:-new)?/(\d+)', url)
    file_match = re.search(r'/record-file/(\d+)', url)
    if not session_match or not file_match:
        raise ValueError("Could not extract the eventSessionId or the recordFileId values from URL!")
    return session_match.group(1), file_match.group(1)

def fetch_flow_data(session_id, file_id):
    api_url = f"https://gw.mts-link.ru/api/event-sessions/{session_id}/record-files/{file_id}/flow?withoutCuts=false"
    req = urllib.request.Request(api_url, headers={
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'
    })
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read().decode('utf-8'))

def get_audio_streams(flow_data):
    streams = {}
    logs = flow_data.get('eventLogs', [])
    for log in logs:
        if log.get('module') == 'mediasession.add':
            data = log.get('data', {})
            hls_url = data.get('hlsUrl')
            if hls_url:
                audio_url = hls_url.replace('/playlist.m3u8', '/a1/index.m3u8')
                relative_time = log.get('relativeTime', 0)
                if audio_url not in streams or relative_time < streams[audio_url]:
                    streams[audio_url] = relative_time
    return streams

def download_and_mix(streams, output_wav):
    print(f"Found {len(streams)} audio streams.")
    
    valid_streams = []
    
    # Download each stream individually to make it robust against 404s/errors
    for idx, (url, delay) in enumerate(sorted(streams.items(), key=lambda x: x[1])):
        tmp_file = f"temp_stream_{idx}.wav"
        print(f"Downloading stream {idx+1}/{len(streams)} (delay {delay:.2f}s)...")
        cmd = [
            'ffmpeg', '-y', '-i', url,
            '-vn', '-acodec', 'pcm_s16le', '-ar', '16000', '-ac', '1', tmp_file
        ]
        try:
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            valid_streams.append((tmp_file, delay))
        except subprocess.CalledProcessError:
            print(f"  -> Failed to download stream {idx+1}, skipping.")
            if os.path.exists(tmp_file):
                os.remove(tmp_file)

    if not valid_streams:
        print("No valid audio streams downloaded.")
        return

    print(f"Successfully downloaded {len(valid_streams)} audio streams. Combining them...")
    
    cmd = ['ffmpeg', '-y']
    filters = []
    for idx, (tmp_file, delay) in enumerate(valid_streams):
        cmd.extend(['-i', tmp_file])
        delay_ms = int(delay * 1000)
        filters.append(f"[{idx}:a]adelay={delay_ms}|{delay_ms}[a{idx}];")
    
    filter_complex = "".join(filters)
    filter_complex += "".join(f"[a{i}]" for i in range(len(valid_streams)))
    
    # amix normalizes the volume down. dropout_transition=0 helps but normalize=0 is only in newer ffmpeg
    filter_complex += f"amix=inputs={len(valid_streams)}:dropout_transition=0:normalize=0[aout]"
    
    cmd.extend([
        '-filter_complex', filter_complex,
        '-map', '[aout]',
        '-acodec', 'pcm_s16le',
        '-ar', '16000',
        '-ac', '1',
        output_wav
    ])
    
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"Successfully saved to {output_wav}")
    except subprocess.CalledProcessError:
        print("Error running ffmpeg mix. Falling back to standard amix without normalize=0...")
        fallback_filter = filter_complex.replace(":normalize=0", "")
        cmd[cmd.index(filter_complex)] = fallback_filter
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"Successfully saved to {output_wav}")

    # Cleanup
    print("Cleaning up temporary files...")
    for tmp_file, _ in valid_streams:
        if os.path.exists(tmp_file):
            os.remove(tmp_file)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 download_webinar.py <webinar_url>")
        sys.exit(1)
        
    url = sys.argv[1]
    print(f"Inspecting URL: {url}")
    session_id, file_id = extract_ids(url)
    print(f"Session ID: {session_id}, File ID: {file_id}")
    
    print("Fetching webinar metadata...")
    flow_data = fetch_flow_data(session_id, file_id)
    
    streams = get_audio_streams(flow_data)
    
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_filename = f"webinar_{session_id}_{file_id}_{timestamp}.wav"
    download_and_mix(streams, output_filename)

if __name__ == '__main__':
    main()
