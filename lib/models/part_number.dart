class PartNumber {
  final String name;
  final String flashId;
  final String vendor;
  final String dirPn;
  final String die;
  final String cellType;
  final String plane;
  final String alias;
  final bool isSelected;

  PartNumber({
    required this.name,
    required this.flashId,
    this.vendor = '',
    this.dirPn = '',
    this.die = '',
    this.cellType = '',
    this.plane = '',
    this.alias = '',
    this.isSelected = false,
  });

  PartNumber copyWith({
    String? name,
    String? flashId,
    String? vendor,
    String? dirPn,
    String? die,
    String? cellType,
    String? plane,
    String? alias,
    bool? isSelected,
  }) {
    return PartNumber(
      name: name ?? this.name,
      flashId: flashId ?? this.flashId,
      vendor: vendor ?? this.vendor,
      dirPn: dirPn ?? this.dirPn,
      die: die ?? this.die,
      cellType: cellType ?? this.cellType,
      plane: plane ?? this.plane,
      alias: alias ?? this.alias,
      isSelected: isSelected ?? this.isSelected,
    );
  }
}
