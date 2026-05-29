import warnings, logging, glob; warnings.filterwarnings("ignore"); logging.disable(logging.WARNING)
from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions
for f in sorted(glob.glob("_debug_uploads/upload_03*.wav")):
    r = analyze_audio(open(f,"rb").read(), AnalyzeOptions())
    pit=[n for n in r.notes if n.kind=='pitched']
    early=[n for n in pit if n.start < 0.6]
    first3=[(round(n.start,2), round(n.end-n.start,2)) for n in pit[:3]]
    print(f"{f.split(chr(92))[-1]:16} notes={len(pit):2} early(<0.6s)={len(early)} first3(start,dur)={first3}")
