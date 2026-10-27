"""Audit the downloaded MIDI with mido, independent of the Dart importer.

Run using backend/.venv/Scripts/python.exe. Creates a note-inspection Studio
project; its procedural preview is explicitly NOT the source's instrument sound.
No user song library is read or written.
"""
import collections
import hashlib
import json
import math
from pathlib import Path

import mido

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/reference-prep'
SOURCE = OUT / 'midi/Attention-HitTrax-demo.mid'


def main():
    midi = mido.MidiFile(SOURCE)
    events = []
    for track, messages in enumerate(midi.tracks):
        tick = 0
        for index, msg in enumerate(messages):
            tick += msg.time
            events.append((tick, track, index, msg))
    events.sort(key=lambda e: e[:3])
    programs = [0] * 16
    held = collections.defaultdict(collections.deque)
    notes, controller_counts = [], collections.Counter()
    for tick, track, _, msg in events:
        if msg.type == 'program_change':
            programs[msg.channel] = msg.program
        elif msg.type == 'control_change':
            controller_counts[msg.control] += 1
        elif msg.type == 'note_on' and msg.velocity > 0:
            n = dict(track=track, channel=msg.channel, program=programs[msg.channel],
                     pitch=msg.note, velocity=msg.velocity, tick=tick)
            notes.append(n)
            held[(msg.channel, msg.note)].append(n)
        elif msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0):
            q = held[(msg.channel, msg.note)]
            if q:
                n = q.popleft(); n['endTick'] = max(n['tick']+1, tick)
    assert all('endTick' in n for n in notes), 'Source has unpaired notes'
    audit_path = OUT / 'evidence/source-audit.json'
    audit = json.loads(audit_path.read_text(encoding='utf-8'))
    key = lambda n: (n['channel'], n['program'], n['pitch'], n['velocity'], n['tick'], n['endTick'])
    dart_notes = [dict(n, channel=l['channel'], program=l['program'])
                  for l in audit['lanes'] for n in l['notes']]
    assert sorted(map(key, notes)) == sorted(map(key, dart_notes)), 'Dart/mido mismatch'

    # Independent export check: selected bars retain every audible note's
    # pitch, attack strength and exact (possibly fractional) start/end.
    exported = mido.MidiFile(OUT / 'evidence/attention-humtrack.mid')
    actual, pending = [], collections.defaultdict(collections.deque)
    tick = 0
    for msg in mido.merge_tracks(exported.tracks):
        tick += msg.time
        if msg.type == 'note_on' and msg.velocity:
            item = [msg.note, msg.velocity, tick / exported.ticks_per_beat, None]
            actual.append(item); pending[msg.channel, msg.note].append(item)
        elif msg.type == 'note_off' or (msg.type == 'note_on' and not msg.velocity):
            q = pending[msg.channel, msg.note]
            if q: q.popleft()[3] = tick / exported.ticks_per_beat
    start, end = 16 * midi.ticks_per_beat, 32 * midi.ticks_per_beat
    expected = sorted((n['pitch'], n['velocity'],
        (max(n['tick'],start)-start)/midi.ticks_per_beat,
        (min(n['endTick'],end)-start)/midi.ticks_per_beat)
        for n in notes if n['tick'] < end and n['endTick'] > start)
    actual.sort()
    assert len(actual) == len(expected)
    assert all(a[:2] == list(e[:2]) and abs(a[2]-e[2]) < .00011 and abs(a[3]-e[3]) < .00011
               for a,e in zip(actual, expected)), 'Export changed note data'

    # One lane per part; drums split by key to preserve the displayed hit types.
    channels, studio_notes = [], []
    channel_ids = {}
    name_of = {l['id']: l['name'] for l in audit['lanes']}
    for i, n in enumerate(notes):
        grouping = (n['track'], n['channel'], n['program'], n['pitch'] if n['channel'] == 9 else -1)
        if grouping not in channel_ids:
            cid = channel_ids[grouping] = f'midi-{len(channel_ids)}'
            kind = ('kick' if n['pitch'] in [35, 36] else 'snare' if n['pitch'] in [37,38,39,40] else 'hat') if n['channel'] == 9 else (
                'bass' if 32 <= n['program'] <= 39 else 'lead')
            name = name_of[f"{n['track']}:{n['channel']}:{n['program']}"]
            if n['channel'] == 9:
                name += f" · key {n['pitch']}"
            channels.append(dict(id=cid, name=name, type='synth', instrument=dict(kind=kind),
                mixer=dict(volume=.35, pan=0, mute=False, solo=False), color='#b5e853'))
        studio_notes.append(dict(id=f'note-{i}', channelId=channel_ids[grouping],
            beat=n['tick']/midi.ticks_per_beat,
            duration=(n['endTick']-n['tick'])/midi.ticks_per_beat,
            pitch=n['pitch'], velocity=n['velocity']/127))
    length = math.ceil(max(n['endTick'] for n in notes)/midi.ticks_per_beat/4)*4
    project = dict(schemaVersion=1, id='attention-reference', title='Attention MIDI reference (approximate preview)',
        tempo=100, beatsPerBar=4, lengthBeats=length, masterVolume=.7,
        loop=dict(enabled=False, startBeat=0, endBeat=length), channels=channels,
        patterns=[dict(id='attention', name='Source MIDI notes', lengthBeats=length, notes=studio_notes)],
        clips=[dict(id='reference', patternId='attention', beat=0, lengthBeats=length)],
        reference=dict(source='https://www.mididb.com/charlie-puth/attention-midi/',
            midiSha256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            limitations='Procedural preview only. Controllers, original timbres and effects are not reproduced.'))
    (OUT/'Attention-reference.hstudio').write_text(json.dumps(project), encoding='utf-8')
    report = dict(source=str(SOURCE), sha256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        download='https://www.mididb.com/midi-download/AUD_DW0160.mid',
        isFullSong=False, seconds=midi.length, sourceNotes=len(notes), sourceChannels=len({n['channel'] for n in notes}),
        controllers=dict(controller_counts), dartParserMatchesMido=True,
        studioChannels=len(channels), studioNotes=len(studio_notes),
        humtrackPassageBars=[5,8], humtrackPassageNotes=audit['passageNoteCount'],
        independentExportRoundtripMatches=True)
    (OUT/'evidence/independent-midi-audit.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
