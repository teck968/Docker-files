/mnt/JN50Tb1/data/openmemory/
├── database/
│   └── openmemory.db          # ← SQLite database (persistent)
└── qdrant/
    ├── storage/               # ← Vector data (persistent)
    └── snapshots/             # ← Qdrant backups (persistent)

sudo mkdir -p /mnt/JN50Tb1/data/openmemory/{qdrant/storage,qdrant/snapshots,database}
sudo chown -R root:Management /mnt/JN50Tb1/data/openmemory/{qdrant/storage,qdrant/snapshots,database} && sudo chmod -R 775 /mnt/JN50Tb1/data/openmemory/{qdrant/storage,qdrant/snapshots,database}