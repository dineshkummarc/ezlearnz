require File.dirname(__FILE__) + '/../sass'
require 'sass/tree/node'
require 'strscan'

module Sass
  # :stopdoc:
  module Tree
    class Node
      def to_sass
        result = ''

        children.each do |child|
          result << "#{child.to_sass(0)}\n"
        end

        result
      end
    end

    class ValueNode
      def to_sass(tabs)
        "#{value}\n"
      end
    end

    class RuleNode
      def to_sass(tabs)
        str = "#{'  ' * tabs}#{rule}\n"

        children.each do |child|
          str << "#{child.to_sass(tabs + 1)}"
        end

        str
      end
    end

    class AttrNode
      def to_sass(tabs)
        "#{'  ' * tabs}:#{name} #{value}\n"
      end
    end
  end

  # This class is based on the Ruby 1.9 ordered hashes.
  # It keeps the semantics and most of the efficiency of normal hashes
  # while also keeping track of the order in which elements were set.
  class OrderedHash
    Node = Struct.new('Node', :key, :value, :next)
    include Enumerable

    def initialize
      @hash = {}
    end

    def [](key)
      @hash[key] && @hash[key].value
    end

    def []=(key, value)
      node = Node.new(key, value, nil)
      if @first.nil?
        @first = @last = node
      else
        @last.next = node
        @last = node
      end
      @hash[key] = node
      value
    end

    def each
      return unless @first
      yield [@first.key, @first.value]
      node = @first
      yield [node.key, node.value] while node = node.next
      self
    end

    def values
      self.map { |k, v| v }
    end
  end

  # :startdoc:

  # This class contains the functionality used in the +css2sass+ utility,
  # namely converting CSS documents to Sass templates.
  class CSS

    # Creates a new instance of Sass::CSS that will compile the given document
    # to a Sass string when +render+ is called.
    def initialize(template)
      if template.is_a? IO
        template = template.read
      end

      @template = StringScanner.new(template)
    end

    # Processes the document and returns the result as a string
    # containing the CSS template.
    def render
      begin
        build_tree.to_sass
      rescue Exception => err
        line = @template.string[0...@template.pos].split("\n").size
        
        err.backtrace.unshift "(css):#{line}"
        raise err
      end
    end

    private

    def build_tree
      root = Tree::Node.new(nil)
      whitespace
      directives    root
      rules         root
      expand_commas root
      nest_rules    root
      flatten_rules root
      fold_commas   root
      root
    end

    def directives(root)
      while @template.scan(/@/)
        name = @template.scan /[^\s;]+/
        whitespace
        value = @template.scan /[^;]+/
        assert_match /;/
        whitespace

        if name == "import" && value =~ /^(url\()?"?([^\s\(\)\"]+)\.css"?\)?$/
          value = $2
        end

        root << Tree::ValueNode.new("@#{name} #{value};", nil)
      end
    end

    def rules(root)
      rules = []
      while @template.scan(/[^\{\s]+/)
        rules << @template[0]
        whitespace

        if @template.scan(/\{/)
          result = Tree::RuleNode.new(rules.join(' '), nil)
          root << result
          rules = []

          whitespace
          attributes(result)
        end
      end
    end

    def attributes(rule)
      while @template.scan(/[^:\}\s]+/)
        name = @template[0]
        whitespace

        assert_match /:/
        
        value = ''
        while @template.scan(/[^;\s\}]+/)
          value << @template[0] << whitespace
        end
        
        assert_match /(;|(?=\}))/
        rule << Tree::AttrNode.new(name, value, nil)
      end

      assert_match /\}/
    end

    def whitespace
      space = @template.scan(/\s*/) || ''

      # If we've hit a comment,
      # go past it and look for more whitespace
      if @template.scan(/\/\*/)
        @template.scan_until(/\*\//)
        return space + whitespace
      end
      return space
    end

    def assert_match(re)
      if !@template.scan(re)
        raise Exception.new("Invalid CSS!")
      end
      whitespace
    end

    # Transform
    #
    #   foo, bar, baz
    #     color: blue
    #
    # into
    #
    #   foo
    #     color: blue
    #   bar
    #     color: blue
    #   baz
    #     color: blue
    #
    # Yes, this expands the amount of code,
    # but it's necessary to get nesting to work properly.
    def expand_commas(root)
      root.children.map! do |child|
        next child unless Tree::RuleNode === child && child.rule.include?(',')
        child.rule.split(',').map do |rule|
          node = Tree::RuleNode.new(rule, nil)
          node.children = child.children
          node
        end
      end
      root.children.flatten!
    end

    # Nest rules so that
    #
    #   foo
    #     color: green
    #   foo bar
    #     color: red
    #   foo baz
    #     color: blue
    #
    # becomes
    #
    #   foo
    #     color: green
    #     bar
    #       color: red
    #     baz
    #       color: blue
    # 
    def nest_rules(root)
      rules = OrderedHash.new
      root.children.select { |c| Tree::RuleNode === c }.each do |child|
        root.children.delete child
        first, rest = child.rule.split(' ', 2)
        rules[first] ||= Tree::RuleNode.new(first, nil)
        if rest
          child.rule = rest
          rules[first] << child
        else
          rules[first].children += child.children
        end
      end

      rules.values.each { |v| nest_rules(v) }
      root.children += rules.values
    end

    # Flatten rules so that
    #
    #   foo
    #     bar
    #       baz
    #         color: red
    #
    # becomes
    #
    #   foo bar baz
    #     color: red
    # 
    def flatten_rules(root)
      root.children.each { |child| flatten_rule(child) if child.is_a?(Tree::RuleNode) }
    end

    def flatten_rule(rule)
      while rule.children.size == 1 && rule.children.first.is_a?(Tree::RuleNode)
        child = rule.children.first
        rule.rule = "#{rule.rule} #{child.rule}"
        rule.children = child.children
      end

      flatten_rules(rule)
    end

    # Transform
    #
    #   foo
    #     bar
    #       color: blue
    #     baz
    #       color: blue
    #
    # into
    #
    #   foo
    #     bar, baz
    #       color: blue
    #
    def fold_commas(root)
      prev_rule = nil
      root.children.map! do |child|
        next child unless Tree::RuleNode === child

        if prev_rule && prev_rule.children == child.children
          prev_rule.rule << ", #{child.rule}"
          next nil
        end

        fold_commas(child)
        prev_rule = child
        child
      end
      root.children.compact!
    end
  end
end
